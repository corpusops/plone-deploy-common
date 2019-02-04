#!/bin/bash
IMAGE_MODE="${IMAGE_MODE-}"
NO_START=${NO_START-}
if [[ -n ${NO_START} ]];then
    while true;do echo "start skipped" >&2;sleep 65535;done
    exit 0
fi
set -e
# load locales & default env
for i in /etc/environment /etc/default/locale;do if [ -e $i ];then . $i;fi;done
PLONE_CONF_PREFIX="${PLONE_CONF_PREFIX:-${CONF_PREFIX:-PLONE__}}"
log() { echo "$@">&2; }
vv() { log "$@";"$@"; }
# Regenerate egg-info & be sure to have it in site-packages
regen_egg_info() {
    local f="$1"
    if [ -e "$f" ];then
        local e="$(dirname "$f")"
        echo "Reinstalling egg-info in: $e" >&2
        ( cd "$e" && python setup.py egg_info ; )
    fi
}
SCRIPTSDIR="$(dirname $(readlink -f "$0"))"
cd "$SCRIPTSDIR/.."
TOPDIR=$(pwd)
VENV=${VENV:-$TOPDIR/venv}
if [ -e "${VENV}/bin/activate" ];then . "$VENV/bin/activate";fi
SDEBUG=${SDEBUG-}
if [[ -n $SDEBUG ]];then set -x;fi
FINDPERMS_PERMS_DIRS_CANDIDATES="${FINDPERMS_PERMS_DIRS_CANDIDATES:-"www"}"
FINDPERMS_OWNERSHIP_DIRS_CANDIDATES="${FINDPERMS_OWNERSHIP_DIRS_CANDIDATES:-"www"}"
export APP_TYPE="${APP_TYPE:-docker}"
export APP_USER="${APP_USER:-$APP_TYPE}"
for i in $TOPDIR/bin $TOPDIR/venv/bin;do
    if [ -e "$i" ];then export PATH=$i:$PATH;fi
done
export APP_GROUP="$APP_USER"
SHELL_USER=${SHELL_USER:-${APP_USER}}
export DATA_DIR="${PLONE__DATA_DIR:-/data}"
export USER_DIRS=". www $DATA_DIR $(find $DATA_DIR -maxdepth 3 -type d) $DATA_DIR/backup"
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
# one of: supervisord | forego
PROCESSES_SUPERVISOR=${PROCESSES_SUPERVISOR:-supervisord}
if (find /etc/sudoers* -type f >/dev/null 2>&1);then chown -Rf root:root /etc/sudoers*;fi
for i in $USER_DIRS;do
    if [ ! -e "$i" ];then mkdir -p "$i";fi
    chown $APP_USER:$APP_GROUP "$i"
done
#### USAGE
echo "Running in $IMAGE_MODE mode" >&2
if ( echo $1 | egrep -q -- "--help|-h|elp" );then
    echo "args:
-e SHELL_USER=\$USER -e IMAGE_MODE=zope|zeo \
    docker run <img> run either zeo or zope client in foreground (IMAGE_MODE: zope|zeo)

-e SHELL_USER=\$USER -e IMAGE_MODE=zope|zeo \
    docker run <img> \$COMMAND \$ARGS (default user: \$SHELL_USER)
  -> run interactive shell or command inside container environment
  "
  exit 0
fi
# regenerate any setup.py found as it can be an egg mounted from a docker volume
# without having a change to be built
while read f;do regen_egg_info "$f";done < <( \
  find "$TOPDIR/setup.py" "$TOPDIR/src" "$TOPDIR/lib" \
    -name setup.py -type f -maxdepth 2 -mindepth 0; )
# install wtih frep any template file to / (eg: logrotate & cron file)
for i in $(find etc/ -name "*.frep" -type f 2>/dev/null);do
    d="$(dirname "$i")/$(basename "$i" .frep)" \
        && di="/$(dirname $d)" \
        && if [ ! -e "$di" ];then mkdir -pv "$di";fi \
        && echo "Generating with frep $i:$d" >&2 \
        && frep "$i:/$d" --overwrite
done
# install wtih envsubst any template file to / (eg: logrotate & cron file)
for i in $(find etc -name "*.envsubst" -type f 2>/dev/null);do
    di="/$(dirname $i)" \
        && if [ ! -e "$di" ];then mkdir -pv "$di";fi \
        && cp "$i" "/$i" \
        && CONF_PREFIX="$PLONE_CONF_PREFIX" confenvsubst.sh "/$i" \
        && rm -f "/$i"
done
if [ -e /etc/cron.d ];then cp -fv /etc/crontabs/{zeo,plone} /etc/cron.d;fi
# if a custom buildout if found, run it
if [ -e "custom.cfg" ]; then
    gosu plone buildout -c custom.cfg
fi
# replace some zope settings to adapt environment (sentry)
gosu plone python "$SCRIPTSDIR/docker-initialize.py"
if [ "x$IMAGE_MODE" = "xzeo" ]; then
    rm -fv /etc/{logrotate.d,crontabs,cron.d}/plone
else
    rm -fv /etc/{logrotate.d,crontabs,cron.d}/zeo
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

fixperms() {
    if [[ -z $NO_FIXPERMS ]];then
        chmod 0640 /etc/cron.d/* /etc/logrotate.d/* /etc/supervisor.d/*
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
    fi
}

_shell() {
    local pre=""
    local user="$APP_USER"
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

#### main
get_sha_passord="from hashlib import sha1;from binascii import b2a_base64;
print(b2a_base64(sha1('$PLONE__ADMIN_PASSWORD'.encode('utf-8')).digest()))"
if [[ -n "$PLONE__ADMIN_PASSWORD" ]];then
    spw="$(python -c "$get_sha_passord")"
    for i in parts/instance parts/instance-plain;do if [ -e $i ];then
        echo "$PLONE__ADMIN:{SHA}$spw">$i/inituser
    fi;done
fi
fixperms
if [[ -z "$@" ]]; then
    if [[ "$PROCESSES_SUPERVISOR" == "supervisord" ]];then
        if ( echo $IMAGE_MODE | egrep -iq zeo );then
            mode=zeo
        else
            mode=zope
        fi
        cfg="/etc/supervisor.d/$mode"
        frep /code$cfg:$cfg --overwrite
        SUPERVISORD_CONFIGS="/etc/supervisor.d/cron $cfg" \
            exec /bin/supervisord.sh
    elif [[ "$PROCESSES_SUPERVISOR" == "forego" ]];then
        export PROCFILE="/code/etc/procfiles/zope"
        if ( echo $1 | egrep -iq zeo );then
            export PROCFILE="/code/procfiles/zeo"
        fi
        exec /bin/forego.sh $2
    else
        echo "No supported processes supervisor"
        exit 1
    fi
else
    _shell $SHELL_USER "$@"
fi
