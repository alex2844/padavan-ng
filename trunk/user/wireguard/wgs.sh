#!/bin/sh

###

WG="wg"
IF_NAME="wg1"
IF_ADDR="$(nvram get vpns_vnet | sed 's/\.0$/.1/')"
IF_MTU=$(nvram get vpns_wg_mtu)
[ "$IF_MTU" ] || IF_MTU=1420
PORT="$(nvram get vpns_wg_port)"

if [ "$(nvram get vpns_wg_ext_addr)" ]; then
    WAN_ADDR="$(nvram get vpns_wg_ext_addr)"
elif [ "$(nvram get ddns_enable_x)" = "1" ]; then
    WAN_ADDR="$(nvram get ddns_hostname_x)"
else
    WAN_ADDR=$(nvram get wan0_ipaddr)
    [ "$WAN_ADDR" == "0.0.0.0" ] && WAN_ADDR="{wan_address}"
fi

IF_PRIVATE=$(nvram get vpns_wg_private)
if [ ! "$IF_PRIVATE" ]; then
    IF_PRIVATE="$($WG genkey)"
    nvram set vpns_wg_private="$IF_PRIVATE"
    nvram set vpns_wg_public="$(echo $IF_PRIVATE | $WG pubkey)"
    nvram commit
fi

EXPORT_CONF="/tmp/client-wg.conf"
POST_SCRIPT="/etc/storage/vpns_post_script.sh"

###

log()
{
    [ -n "$*" ] || return
    echo "$@"
    logger -t wireguard "$@"
}

error()
{
    log "$@"
    exit 1
}

die()
{
    echo "$@" >&2
    exit 1
}

is_started()
{
    ip link show ${IF_NAME} >/dev/null 2>&1
    return $?
}

_net_to_prefix()
{
    [ "$1" ] || return

    echo $1 | awk '
    function count1s(N) {
        r=""
        while(N!=0)
        {
            r=((N%2)?"1":"0") r
            N=int(N/2)
        }
        r=gsub(/1/,"",r)
        return r
    }
    function subnetmaskToPrefix(subnetmask)
    {
        split(subnetmask, v, ".")
        return count1s(v[1]) + count1s(v[2]) + count1s(v[3]) + count1s(v[4])
    }
    { print subnetmaskToPrefix($1) }'
}

_get_ipv6_prefix()
{
    local ipv6_enabled=$(nvram get ip6_service)
    if [ -n "${ipv6_enabled}" ]; then
        local ipv6_lan=$(nvram get ip6_lan_addr)
        if [ -n "${ipv6_lan}" ]; then
            echo "${ipv6_lan}" | sed -E 's/^([0-9a-f:]+)::[0-9a-f:]*$/\1::/'
        fi
    fi
}

_get_dns_servers()
{
    local val
    local dns_servers=""
    for var in dhcp_dns1_x dhcp_dns2_x dhcp_dns3_x dhcp_dnsv6_x; do
        val=$(nvram get ${var})
        [ -n "${val}" ] && dns_servers="${dns_servers}${dns_servers:+, }${val}"
    done
    if [ -z "${dns_servers}" ]; then
        local lan_ip=$(nvram get lan_ipaddr)
        dns_servers="${lan_ip:-${IF_ADDR}}"
    fi
    echo "${dns_servers}"
}

wg_setconf()
{
    local pass rnet rmsk prefix i rlan max peers nvram_modified ipv6_prefix

    is_started || return 0

    ipv6_prefix=$(_get_ipv6_prefix)

    max="$(nvram get vpns_num_x)"
    for i in $(seq 0 $((max-1))); do
        pass=$(nvram get vpns_pass_x$i | $WG pubkey 2>/dev/null)
        [ "$pass" ] || continue
        if [ ! "$(nvram get vpns_public_x$i)" == "$pass" ]; then
            # save public keys to speed up creation of leases
            nvram set vpns_public_x$i="$pass"
            nvram_modified=1
        fi

        rlan=""
        rnet=$(nvram get vpns_rnet_x$i)
        rmsk=$(nvram get vpns_rmsk_x$i)

        if [ "$rnet" -a "$rmsk" ]; then
            prefix=$(_net_to_prefix $rmsk)
            rlan=", $rnet/$prefix"
        fi

        local last_octet=$(nvram get vpns_addr_x$i)
        local allowed_ips="$(nvram get vpns_vnet | sed 's/\.0$/./')${last_octet}/32${rlan}"

        if [ -n "${ipv6_prefix}" ]; then
            local ipv6_addr="${ipv6_prefix}${last_octet}/128"
            allowed_ips="${allowed_ips}, ${ipv6_addr}"
        fi

        peers=$(echo "[Peer]"
                echo "PublicKey=${pass}"
                echo "AllowedIPs=${allowed_ips}"
                echo "${peers}")
    done

    [ "$nvram_modified" ] && nvram commit

    cat > "/tmp/${IF_NAME}.conf.$$" <<EOF
[Interface]
ListenPort=${PORT}
PrivateKey=${IF_PRIVATE}
$peers
EOF

    local res=$($WG setconf ${IF_NAME} "/tmp/${IF_NAME}.conf.$$" 2>&1)
    rm -f "/tmp/${IF_NAME}.conf.$$"
    if ! echo $res | grep -q "error"; then
        log "configuration ${IF_NAME} applied successfully, client count: $($WG show ${IF_NAME} peers | wc -l)"
    else
        log "$res"
        return 1
    fi
}

wg_prepare()
{
    modprobe -q wireguard >/dev/null 2>&1
}

wg_stop()
{
    if is_started; then
        ip link del ${IF_NAME} >/dev/null 2>&1 && log "server stopped"
    fi
}

wg_start()
{
    [ "$(nvram get vpns_type)" == "3" -a "$(nvram get vpns_enable)" == "1" ] || die "disabled"

    is_started && die "already started"
    wg_prepare

    ip link add dev $IF_NAME type wireguard || error "cannot create $IF_NAME"
    ip link set dev $IF_NAME mtu $IF_MTU
    ip addr add ${IF_ADDR}/24 dev $IF_NAME

    local ipv6_prefix=$(_get_ipv6_prefix)
    if [ -n "${ipv6_prefix}" ]; then
        ip -6 addr add ${ipv6_prefix}1/64 dev ${IF_NAME}
    fi

    local if_ip=$(ip addr show dev $IF_NAME | awk '/inet/{print $2}')
    [ "$if_ip" ] || error "$IF_NAME interface address not set"

    wg_setconf || die

    if ip link set $IF_NAME up; then
        log "server started, interface: ${IF_NAME}, address: ${IF_ADDR}:${PORT}"
    else
        ip link del $IF_NAME >/dev/null 2>&1
        die "$IF_NAME startup failed"
    fi

    $WG show $IF_NAME allowed-ips | awk 'NF > 1 {for(i=2; i<=NF; i++) print $i}' | while read addr; do
        if echo "$addr" | grep -q ':'; then
            ip -6 route add "$addr" dev $IF_NAME metric 1 2>/dev/null || \
                log "warning: unable to add IPv6 route to $addr"
        else
            ip route add "$addr" dev $IF_NAME metric 1 2>/dev/null || \
                log "warning: unable to add IPv4 route to $addr"
        fi
    done
}

wg_addclient()
{
    # $1 - client name

    local max nums free_num addr key config

    max="$(nvram get vpns_num_x)"
    nums=$(for i in $(seq 0 $((max-1))); do
        nvram get vpns_addr_x$i
    done)

    [ ! "$nums" ] && ips=1
    free_num=$(seq 2 255 | grep -vwF "$nums" | head -n1)

    name="client${free_num}_wg"
    [ "$1" ] && name="$1"

    for i in $(seq 0 $((max-1))); do
        [ "$(nvram get vpns_user_x$i)" == "$name" ] && die "already exist"
    done

    addr="$(echo $IF_ADDR | sed 's/\.1$//').$free_num"
    key=$($WG genkey)

    nvram set vpns_user_x$max=$name
    nvram set vpns_pass_x$max=$key
    nvram set vpns_public_x$max=$(echo $key | $WG pubkey)
    nvram set vpns_addr_x$max=$free_num
    nvram set vpns_rnet_x$max=""
    nvram set vpns_rmsk_x$max=""
    nvram set vpns_num_x=$((max+1))
    nvram commit

    wg_setconf || return

    local address="${addr}/24"
    local allowed_ips="0.0.0.0/0"
    local dns_servers="$(_get_dns_servers)"
    local ipv6_prefix=$(_get_ipv6_prefix)
    if [ -n "${ipv6_prefix}" ]; then
        local ipv6_addr="${ipv6_prefix}${free_num}/64"
        address="${address}, ${ipv6_addr}"
        allowed_ips="${allowed_ips}, ::/0"
    fi

    read -r -d '' config <<EOF
[Interface]
PrivateKey = ${key}
Address = ${address}
DNS = ${dns_servers}

[Peer]
PublicKey = $(echo $IF_PRIVATE | $WG pubkey)
Endpoint = ${WAN_ADDR}:${PORT}
PersistentKeepalive = 11
AllowedIPs = ${allowed_ips}
EOF

    if [ -x /usr/bin/qrencode ]; then
        echo "$config" | qrencode -t UTF8
    fi
    log "client \"$name\" added"
    echo ---------------------------------------------------------
    echo "$config"
    echo
}

wg_listclients()
{
    local peers public_list users_list max

    max="$(nvram get vpns_num_x)"
    [ "$max" == "0" ] && return

    peers=$($WG show ${IF_NAME} dump 2>/dev/null | awk '
        function bf(bytes){
            if (bytes >= 1024^4) printf "%.1fT", bytes/(1024^3)
            else if (bytes >= 1024^3) printf "%.1fG", bytes/(1024^3)
            else if (bytes >= 1024^2) printf "%.1fM", bytes/(1024^2)
            else if (bytes >= 1024) printf "%.1fK", bytes/1024
            else printf "%d", bytes
        } NR>1 {
        print $1, $5, bf($6), bf($7), gensub("[)(]|:[0-9]+$", "", "", $3), $4}
    ')

    if [ ! "$peers" ]; then
        for i in $(seq 0 $((max-1))); do
            rnet=$(nvram get vpns_rnet_x$i)
            rmsk=$(nvram get vpns_rmsk_x$i)

            rlan=""
            if [ "$rnet" -a "$rmsk" ]; then
                prefix=$(_net_to_prefix $rmsk)
                rlan=",$rnet/$prefix"
            fi
            printf "%-12s %s %s%s\n" $(nvram get vpns_user_x$i) $(nvram get vpns_public_x$i) \
                $(nvram get vpns_vnet | sed 's/\.0$/./')$(nvram get vpns_addr_x$i) "$rlan"
        done
        return
    fi

    users_list=$(nvram show all | grep -E "vpns_user_x[0-9]+=.+" \
            | sed -E "s/vpns_user_x([0-9]*)=/vpns_public_x\1|/")
    public_list=$(nvram show all | grep -E "vpns_public_x[0-9]+=.+" \
            | sed -E "s/vpns_public_x([0-9]*)=/vpns_public_x\1|/")

    echo "$peers" | awk -v list1="$users_list" -v list2="$public_list" '
    BEGIN {
        split(list1, parts1, "\n");
        for (i in parts1) {
            split(parts1[i], keyval, "|");
            a[keyval[1]] = keyval[2];
        }

        split(list2, parts2, "\n");
        for (i in parts2) {
            split(parts2[i], keyval, "|");
            b[keyval[1]] = keyval[2]
        }

        for (key in a) {
            if (key in b) {
                c[b[key]] = a[key];
            }
        }
    } { printf "%-12s %s %s ↓%s ↑%s %s %s\n", c[$1], $1, $2, $3, $4, $5, $6, $7}'
}

wg_export()
{
    [ "$1" ] || return

    local i max

    rm -f "$EXPORT_CONF"

    local ipv6_prefix=$(_get_ipv6_prefix)

    max="$(nvram get vpns_num_x)"
    for i in $(seq 0 $((max-1))); do
        [ ! "$(nvram get vpns_user_x$i)" == "$1" ] && continue

        local addr="$(nvram get vpns_vnet | sed 's/\.0$/./')$(nvram get vpns_addr_x$i)"
        local last_octet="$(nvram get vpns_addr_x$i)"

        local dns_servers="$(_get_dns_servers)"
        local address="${addr}/24"
        local allowed_ips="0.0.0.0/0"
        if [ -n "${ipv6_prefix}" ]; then
            local ipv6_addr="${ipv6_prefix}${last_octet}/64"
            address="${address}, ${ipv6_addr}"
            allowed_ips="${allowed_ips}, ::/0"
        fi

        tee "$EXPORT_CONF" <<EOF
[Interface]
PrivateKey = $(nvram get vpns_pass_x$i)
Address = ${address}
DNS = ${dns_servers}

[Peer]
PublicKey = $(nvram get vpns_wg_public)
Endpoint = ${WAN_ADDR}:${PORT}
PersistentKeepalive = 11
AllowedIPs = ${allowed_ips}
EOF
    done

    chmod 0600 "$EXPORT_CONF" || die "not found"
}

case "$1" in
    start)
        wg_start
    ;;

    stop)
        wg_stop
    ;;

    restart)
        wg_stop
        wg_start
    ;;

    export)
        wg_export "$2"
    ;;

    status)
        is_started
    ;;

    add)
        wg_addclient "$2"
    ;;

    list)
        wg_listclients
    ;;

    *)
        echo "Usage: $0 { start|stop|restart|list| { export|add [client name] } }" >&2
        exit 1
    ;;
esac

# IF_NAME
# IF_ADDR
# PORT
# WAN_ADDR

[ -s "$POST_SCRIPT" -a -x "$POST_SCRIPT" ] && . "$POST_SCRIPT"
