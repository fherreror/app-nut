#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community App: Network UPS Tools
# Configures Network UPS Tools
# ==============================================================================
readonly USERS_CONF=/etc/nut/upsd.users
readonly UPSD_CONF=/etc/nut/upsd.conf
readonly TLS_PEMFILE=/run/nut/upsd.pem
declare nutmode
declare password
declare tls_certfile
declare tls_keyfile
declare shutdowncmd
declare upsmon
declare upsmonpwd
declare username

mkdir -p /var/state/ups
mkdir -p /run/nut
chown root:root /run/nut
chmod 0770 /run/nut

chown -R root:root /etc/nut
find /etc/nut -not -perm 0660 -type f -exec chmod 0660 {} \;
find /etc/nut -not -perm 0770 -type d -exec chmod 0770 {} \;

nutmode=$(bashio::config 'mode')
bashio::log.info "Setting mode to ${nutmode}..."
sed -i "s#%%nutmode%%#${nutmode}#g" /etc/nut/nut.conf

if bashio::config.true 'list_usb_devices' ;then
    bashio::log.info "Connected USB devices:"
    lsusb
fi

if bashio::config.equals 'mode' 'netserver' ;then
    bashio::log.info "Generating ${USERS_CONF}..."

    # Create Monitor User
    upsmonpwd=$(shuf -ze -n20  {A..Z} {a..z} {0..9}|tr -d '\0')
    {
        echo
        echo "[upsmonmaster]"
        echo "  password = ${upsmonpwd}"
        echo "  upsmon primary"
    } >> "${USERS_CONF}"

    for user in $(bashio::config "users|keys"); do
        bashio::config.require.username "users[${user}].username"
        username=$(bashio::config "users[${user}].username")

        bashio::log.info "Configuring user: ${username}"
        if ! bashio::config.true 'i_like_to_be_pwned'; then
            bashio::config.require.safe_password "users[${user}].password"
        else
            bashio::config.require.password "users[${user}].password"
        fi
        password=$(bashio::config "users[${user}].password")

        {
            echo
            echo "[${username}]"
            echo "  password = ${password}"
        } >> "${USERS_CONF}"

        for instcmd in $(bashio::config "users[${user}].instcmds"); do
            echo "  instcmds = ${instcmd}" >> "${USERS_CONF}"
        done

        for action in $(bashio::config "users[${user}].actions"); do
            echo "  actions = ${action}" >> "${USERS_CONF}"
        done

        if bashio::config.has_value "users[${user}].upsmon"; then
            upsmon=$(bashio::config "users[${user}].upsmon")
            [[ "${upsmon}" == "master" ]] && upsmon="primary"
            [[ "${upsmon}" == "slave" ]] && upsmon="secondary"
            echo "  upsmon ${upsmon}" >> "${USERS_CONF}"
        fi
    done

    if bashio::config.has_value "upsd_maxage"; then
        maxage=$(bashio::config "upsd_maxage")
        echo "MAXAGE ${maxage}" >> "${UPSD_CONF}"
    fi

    if bashio::config.true 'tls'; then
        bashio::log.info "Enabling TLS for NUT server..."

        tls_certfile=$(bashio::config 'tls_certfile')
        tls_keyfile=$(bashio::config 'tls_keyfile')

        if [[ -z "${tls_certfile}" ]]; then
            bashio::exit.nok "TLS is enabled but tls_certfile is empty"
        fi

        if [[ -z "${tls_keyfile}" ]]; then
            bashio::exit.nok "TLS is enabled but tls_keyfile is empty"
        fi

        if [[ ! -r "${tls_certfile}" ]]; then
            bashio::exit.nok "TLS is enabled but ${tls_certfile} is not readable"
        fi

        if [[ ! -r "${tls_keyfile}" ]]; then
            bashio::exit.nok "TLS is enabled but ${tls_keyfile} is not readable"
        fi

        {
            cat "${tls_certfile}"
            printf '\n'
            cat "${tls_keyfile}"
        } > "${TLS_PEMFILE}"

        chmod 0600 "${TLS_PEMFILE}"

        {
            echo "CERTFILE ${TLS_PEMFILE}"
            echo "DISABLE_WEAK_SSL true"
        } >> "${UPSD_CONF}"
    fi

    for device in $(bashio::config "devices|keys"); do
        upsname=$(bashio::config "devices[${device}].name")
        upsdriver=$(bashio::config "devices[${device}].driver")
        upsport=$(bashio::config "devices[${device}].port")
        if bashio::config.has_value "devices[${device}].powervalue"; then
            upspowervalue=$(bashio::config "devices[${device}].powervalue")
        else
            upspowervalue="1"
        fi

        bashio::log.info "Configuring Device named ${upsname}..."
        {
            echo
            echo "[${upsname}]"
            echo "  driver = ${upsdriver}"
            echo "  port = ${upsport}"
        } >> /etc/nut/ups.conf

        OIFS=$IFS
        IFS=$'\n'
        for configitem in $(bashio::config "devices[${device}].config"); do
            echo "  ${configitem}" >> /etc/nut/ups.conf
        done
        IFS="$OIFS"

        echo "MONITOR ${upsname}@localhost ${upspowervalue} upsmonmaster ${upsmonpwd} primary" \
            >> /etc/nut/upsmon.conf

        bashio::log.info "Registering supervised driver service for ${upsname}..."
        mkdir -p "/etc/services.d/nut-driver-${upsname}"
        {
            echo "#!/command/with-contenv bashio"
            echo "if bashio::debug; then"
            echo "    exec /usr/libexec/nut/${upsdriver} -F -D -u root -a ${upsname}"
            echo "else"
            echo "    exec /usr/libexec/nut/${upsdriver} -F -u root -a ${upsname}"
            echo "fi"
        } > "/etc/services.d/nut-driver-${upsname}/run"
        chmod +x "/etc/services.d/nut-driver-${upsname}/run"

        {
            echo "#!/command/with-contenv bashio"
            echo "bashio::log.warning \"UPS driver for ${upsname} stopped, restarting...\""
        } > "/etc/services.d/nut-driver-${upsname}/finish"
        chmod +x "/etc/services.d/nut-driver-${upsname}/finish"
    done
fi

shutdowncmd="/run/s6/basedir/bin/halt"
if bashio::config.true 'shutdown_host'; then
    bashio::log.warning "UPS Shutdown will shutdown the host"
    shutdowncmd="/usr/bin/shutdownhost"
fi

echo "SHUTDOWNCMD  ${shutdowncmd}" >> /etc/nut/upsmon.conf
