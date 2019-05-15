#!/bin/bash
SDEBUG=${SDEBUG-}
SCRIPTSDIR="$(dirname $(readlink -f "$0"))"
cd "$SCRIPTSDIR/.."
TOPDIR=$(pwd)

# now be in stop-on-error mode
set -e
# load locales & default env
# load this first as it resets $PATH
for i in /etc/environment /etc/default/locale;do
    if [ -e $i ];then . $i;fi
done

# load virtualenv if any
for VENV in ./venv ../venv;do
    if [ -e $VENV ];then . $VENV/bin/activate;break;fi
done
# activate shell debug if SDEBUG is set
if [[ -n $SDEBUG ]];then set -x;fi

DEFAULT_IMAGE_MODE=plone
export IMAGE_MODE=${IMAGE_MODE:-${DEFAULT_IMAGE_MODE}}
IMAGE_MODES="(zeo|plone|fg)"
NO_START=${NO_START-}
NO_FIXPERMS=${NO_FIXPERMS-}
if [[ -n $@ ]];then
    NO_STARTUP_LOGS=${NO_STARTUP_LOGS-1}
else
    NO_STARTUP_LOGS=${NO_STARTUP_LOGS-}
fi
NO_IMAGE_SETUP="${NO_IMAGE_SETUP:-"1"}"
FORCE_IMAGE_SETUP="${FORCE_IMAGE_SETUP:-"1"}"
DO_IMAGE_SETUP_MODES="${DO_IMAGE_SETUP_MODES:-"fg|zeo|plone"}"

FINDPERMS_PERMS_DIRS_CANDIDATES="${FINDPERMS_PERMS_DIRS_CANDIDATES:-"www"}"
FINDPERMS_OWNERSHIP_DIRS_CANDIDATES="${FINDPERMS_OWNERSHIP_DIRS_CANDIDATES:-"www"}"
export APP_TYPE="${APP_TYPE:-docker}"
export APP_USER="${APP_USER:-$APP_TYPE}"
export APP_GROUP="$APP_USER"
export USER_DIRS=". www $DATA_DIR $(find $DATA_DIR -maxdepth 3 -type d) $DATA_DIR/backup"
SHELL_USER=${SHELL_USER:-${APP_USER}}
for i in $TOPDIR/bin $VENV/bin;do
    if [ -e "$i" ];then export PATH=$i:$PATH;fi
done

# plone variables
export DATA_DIR="${PLONE__DATA_DIR:-/data}"
export PLONE_CONF_PREFIX="${PLONE_CONF_PREFIX:-${CONF_PREFIX:-PLONE__}}"
export PLONE__ADMIN="${PLONE__ADMIN:-admin}"
export PLONE__ADMIN_PASSWORD="${PLONE__ADMIN_PASSWORD-}"
export PLONE__PACK_DAYS="${PLONE__PACK_DAYS-}"
export PLONE__BACKUPS_KEEP="${PLONE__BACKUPS_KEEP-}"
export PLONE__SNAPSHOTBACKUPS_KEEP="${PLONE__SNAPSHOTBACKUPS_KEEP-}"
export PLONE__CRON_RESTART="${PLONE__CRON_RESTART:-"15 3 1 * *"}"
export PLONE__CRON_ZEO_PACK="${PLONE__CRON_ZEO_PACK:-"30 1 * * *"}"
export PLONE__CRON_BACKUP="${PLONE__CRON_BACKUP:-"5 1 * * *"}"
export PLONE__CRON_SBACKUP="${PLONE__CRON_SBACKUP:-"10 1 * * 6"}"
DEFAULT_PLONE_VERSION="{{cookiecutter.plone_ver}}"
if [ -e PLONE_VERSION ];then DEFAULT_PLONE_VERSION=$(cat PLONE_VERSION);fi
export PLONE_VERSION=${PLONE_VERSION:-${DEFAULT_PLONE_VERSION}}
export PLONE_VERSION_1=$(echo $PLONE_VERSION|sed -re "s/\.[^.]$//g")
get_sha_passord="from hashlib import sha1;from binascii import b2a_base64;
print(b2a_base64(sha1('$PLONE__ADMIN_PASSWORD'.encode('utf-8')).digest()))"
# in shell mode: deactivate crons
if [[ -n $@ ]];then
    PLONE__PERIODIC_RESTART=
    PLONE__BACKUPS_KEEP=
    PLONE__SNAPSHOTBACKUPS_KEEP=
fi

log() {
    echo "$@" >&2;
}

vv() {
    log "$@";"$@";
}

# Regenerate egg-info & be sure to have it in site-packages
regen_egg_info() {
    local f="$1"
    if [ -e "$f" ];then
        local e="$(dirname "$f")"
        echo "Reinstalling egg-info in: $e" >&2
        ( cd "$e" && gosu $APP_USER python setup.py egg_info >/dev/null 2>&1; )
    fi
}

#  shell: Run interactive shell inside container
_shell() {
    local pre=""
    local user="$SHELL_USER"
    if [[ -n $1 ]];then user=$1;shift;fi
    local bargs="$@"
    local NO_VIRTUALENV=${NO_VIRTUALENV-}
    local NO_NVM=${NO_VIRTUALENV-}
    local NVMRC=${NVMRC:-.nvmrc}
    local NVM_PATH=${NVM_PATH:-..}
    local NVM_PATHS=${NVMS_PATH:-${NVM_PATH}}
    local VENV_NAME=${VENV_NAME:-venv}
    local VENV_PATHS=${VENV_PATHS:-./$VENV_NAME ../$VENV_NAME}
    local DOCKER_SHELL=${DOCKER_SHELL-}
    local pre="DOCKER_SHELL=\"$DOCKER_SHELL\";touch \$HOME/.control_bash_rc;
    if [ \"x\$DOCKER_SHELL\" = \"x\" ];then
        if ( bash --version >/dev/null 2>&1 );then \
            DOCKER_SHELL=\"bash\"; else DOCKER_SHELL=\"sh\";fi;
    fi"
    if [[ -z "$NO_NVM" ]];then
        if [[ -n "$pre" ]];then pre=" && $pre";fi
        pre="for i in $NVM_PATHS;do \
        if [ -e \$i/$NVMRC ] && ( nvm --help > /dev/null );then \
            printf \"\ncd \$i && nvm install \
            && nvm use && cd - && break\n\">>\$HOME/.control_bash_rc; \
        fi;done $pre"
    fi
    if [[ -z "$NO_VIRTUALENV" ]];then
        if [[ -n "$pre" ]];then pre=" && $pre";fi
        pre="for i in $VENV_PATHS;do \
        if [ -e \$i/bin/activate ];then \
            printf \"\n. \$i/bin/activate\n\">>\$HOME/.control_bash_rc && break;\
        fi;done $pre"
    fi
    if [[ -z "$bargs" ]];then
        bargs="$pre && if ( echo \"\$DOCKER_SHELL\" | grep -q bash );then \
            exec bash --init-file \$HOME/.control_bash_rc -i;\
            else . \$HOME/.control_bash_rc && exec sh -i;fi"
    else
        bargs="$pre && . \$HOME/.control_bash_rc && \$DOCKER_SHELL -c \"$bargs\""
    fi
    export TERM="$TERM"; export COLUMNS="$COLUMNS"; export LINES="$LINES"
    exec gosu $user sh $( if [[ -z "$bargs" ]];then echo "-i";fi ) -c "$bargs"
}

#  configure: generate configs from template at runtime
configure() {
    if [[ -n $NO_CONFIGURE ]];then return 0;fi
    for i in $USER_DIRS;do
        if [ ! -e "$i" ];then mkdir -p "$i" >&2;fi
        chown $APP_USER:$APP_GROUP "$i"
    done
    if (find /etc/sudoers* -type f >/dev/null 2>&1);then chown -Rf root:root /etc/sudoers*;fi
    # regenerate any setup.py found as it can be an egg mounted from a docker volume
    # without having a chance to be built
    while read f;do regen_egg_info "$f";done < <( \
        find "$TOPDIR/setup.py" "$TOPDIR/src" "$TOPDIR/lib" \
        -maxdepth 2 -mindepth 0 -name setup.py -type f 2>/dev/null; )
    # copy only if not existing template configs from common deploy project
    # and only if we have that common deploy project inside the image
    if [ ! -e etc ];then mkdir etc;fi
    for i in local/*deploy-common/etc local/*deploy-common/sys/etc sys/etc;do
        if [ -d $i ];then cp -rfnv $i/* etc >&2;fi
    done
    # install wtih envsubst any template file to / (eg: logrotate & cron file)
    for i in $(find etc -name "*.envsubst" -type f 2>/dev/null);do
        di="/$(dirname $i)" \
            && if [ ! -e "$di" ];then mkdir -pv "$di" >&2;fi \
            && cp "$i" "/$i" \
            && CONF_PREFIX="$PLONE_CONF_PREFIX" confenvsubst.sh "/$i" \
            && rm -f "/$i"
    done
    # install wtih frep any template file to / (eg: logrotate & cron file)
    for i in $(find etc -name "*.frep" -type f 2>/dev/null);do
        d="$(dirname "$i")/$(basename "$i" .frep)" \
            && di="/$(dirname $d)" \
            && if [ ! -e "$di" ];then mkdir -pv "$di" >&2;fi \
            && echo "Generating with frep $i:/$d" >&2 \
            && frep "$i:/$d" --overwrite
    done
    # alpine linux has /etc/crontabs/ and ubuntu based vixie has /etc/cron.d/
    if [ -e /etc/cron.d ];then cp -fv /etc/crontabs/{zeo,plone} /etc/cron.d >&2;fi
    # replace some plone settings to adapt environment (sentry)
    if [ "x$IMAGE_MODE" = "xzeo" ]; then
        rm -fv /etc/{logrotate.d,crontabs,cron.d}/plone >&2
    else
        rm -fv /etc/{logrotate.d,crontabs,cron.d}/zeo >&2
    fi
    if [ -e /etc/cron.d/plone ] && [[ -z $PLONE__PERIODIC_RESTART ]];then
            log "deactivating periodic restart"
            sed -i -re "s/(.*restart plone)/#\1/g" /etc/cron.d/plone
    fi
    if [ -e /etc/cron.d/zeo ];then
        if [ -e "$TOPDIR/bin/backup" ] && [[ -n $PLONE__BACKUPS_KEEP ]];then
            log "backups days: $PLONE__BACKUPS_KEEP"
            sed -i \
                -re "s/(keep|keep_blob_days)=[0-9]+,/\1=$PLONE__BACKUPS_KEEP,/g" \
                "$TOPDIR/bin/backup"
        else
            log "deactivating backups"
            sed -i -re "s/(.*bin\/backup)/#\1/g" /etc/cron.d/zeo
        fi
        if ( ls /code/bin/*pack* &>/dev/null ) && [[ -n $PLONE__PACK_DAYS ]];then
            log "packs days: $PLONE__PACK_DAYS"
            sed -i \
                -re "s/(.*pack.*-D )[0-9]+(.*)/\1$PLONE__PACK_DAYS\2/g" \
                /etc/cron.d/zeo
        else
            log "deactivating packs"
            sed -i -re "s/(.*pack)/#\1/g" /etc/cron.d/zeo
        fi
        if [ -e "$TOPDIR/bin/snapshotbackup" ] && [[ -n $PLONE__SNAPSHOTBACKUPS_KEEP ]];then
            log "snapshotbackups days: $PLONE__SNAPSHOTBACKUPS_KEEP"
            sed -i \
                -re "s/(keep|keep_blob_days)=[0-9]+,/\1=$PLONE__SNAPSHOTBACKUPS_KEEP,/g" \
                "$TOPDIR/bin/snapshotbackup"
        else
             log "deactivating snapshotbackups"
            sed -i -re "s/(.*bin\/snapshotbackup)/#\1/g" /etc/cron.d/zeo
        fi
    fi
    if [[ -n "$PLONE__ADMIN_PASSWORD" ]];then
        spw="$(python -c "$get_sha_passord")"
        for i in parts/instance parts/instance-plain;do if [ -e $i ];then
            echo "$PLONE__ADMIN:{SHA}$spw">$i/inituser
        fi;done
    fi
    gosu plone python "$SCRIPTSDIR/docker-initialize.py"
}

fixperms() {
    if [[ -n $NO_FIXPERMS ]];then return 0;fi
    for i in /etc/{crontabs,cron.d} /etc/logrotate.d /etc/supervisor.d;do
        if [ -e $i ];then
            while read f;do
                chown -R root:root "$f"
                chmod 0640 "$f"
            done < <(find "$i" -type f)
        fi
    done
    while read f;do chmod 0755 "$f";done < \
        <(find $FINDPERMS_PERMS_DIRS_CANDIDATES -type d \
          -not \( -perm 0755 \) |sort)
    while read f;do chmod 0644 "$f";done < \
        <(find $FINDPERMS_PERMS_DIRS_CANDIDATES -type f \
          -not \( -perm 0644 \) |sort)
    while read f;do chown $APP_USER:$APP_USER "$f";done < \
        <(find $FINDPERMS_OWNERSHIP_DIRS_CANDIDATES \
          \( -type d -or -type f \) \
          -and -not \( -user $APP_USER -and -group $APP_GROUP \) |sort)
}

#  services_setup: when image run in daemon mode: pre start setup
#               like database migrations, etc
services_setup() {
    if [[ -z $NO_IMAGE_SETUP ]];then
        if [[ -n $FORCE_IMAGE_SETUP ]] || ( echo $IMAGE_MODE | egrep -q "$DO_IMAGE_SETUP_MODES" ) ;then
            : "continue services_setup"
        else
            log "No image setup"
            return 0
        fi
    else
        if [[ -n $SDEBUG ]];then
            log "Skip image setup"
            return 0
        fi
    fi
    # if a custom buildout if found, run it
    if [ -e "custom.cfg" ]; then
        gosu plone buildout -c custom.cfg
    fi
}

#  usage: print this help
usage() {
    drun="docker run --rm -it <img>"
    echo "EX:
$drun [ -e FORCE_IMAGE_SETUP] [-e IMAGE_MODE=\$mode]
    docker run <img>
        run either plone, or zeo daemon
        (IMAGE_MODE: $IMAGE_MODES)

$drun \$args: run commands with the context ignited inside the container
$drun [ -e NO_FIXPERMS=1 ] [ -e FORCE_IMAGE_SETUP=1] [ -e NO_IMAGE_SETUP=1] [-e SHELL_USER=\$ANOTHERUSER] [-e IMAGE_MODE=\$mode] [\$command[ \args]]
    docker run <img> \$COMMAND \$ARGS -> run command
    docker run <img> shell -> interactive shell
(default user: $SHELL_USER)
(default mode: $IMAGE_MODE)

If FORCE_IMAGE_SETUP is set: run migrate/collect static
If NO_IMAGE_SETUP is set: migrate/collect static is skipped, no matter what
If NO_START is set: start an infinite loop doing nothing (for dummy containers in dev)
"
  exit 0
}

do_fg() {
    exec gosu $APP_USER bin/instance fg
}

if ( echo $1 | egrep -q -- "--help|-h|help" );then
    usage
fi

if [[ -n ${NO_START-} ]];then
    while true;do echo "start skipped" >&2;sleep 65535;done
    exit $?
fi

# Run app
pre() {
    configure
    services_setup
    fixperms
}
# only display startup logs when we start in daemon mode
# and try to hide most when starting an (eventually interactive) shell.
if [[ -n $NO_STARTUP_LOGS ]];then pre 2>/dev/null;else pre;fi

if [[ -z "$@" ]]; then
    if ! ( echo $IMAGE_MODE | egrep -q "$IMAGE_MODES" );then
        log "Unknown image mode ($IMAGE_MODES): $IMAGE_MODE"
        exit 1
    fi
    log "Running in $IMAGE_MODE mode"
    if [[ "$IMAGE_MODE" = "fg" ]]; then
        do_fg
    else
        cfg="/etc/supervisor.d/$IMAGE_MODE"
        if [ ! -e $cfg ];then
            log "Missing: $cfg"
            exit 1
        fi
        SUPERVISORD_CONFIGS="/etc/supervisor.d/cron /etc/supervisor.d/rsyslog $cfg" exec /bin/supervisord.sh
    fi
else
    if [[ "${1-}" = "shell" ]];then shift;fi
    _shell $SHELL_USER "$@"
fi
