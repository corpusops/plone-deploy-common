ARG BASE=corpusops/ubuntu-bare:bionic
FROM $BASE
ARG BUILDOUT=buildout.cfg
ARG TZ=Europe/Paris
ARG BUILD_DEV=y
ARG PY_VER=2.7
# See https://github.com/nodejs/docker-node/issues/380
ARG GPG_KEYS=B42F6819007F00F88E364FD4036A9C25BF357DD4
ARG GPG_KEYS_SERVERS="hkp://p80.pool.sks-keyservers.net:80 hkp://ipv4.pool.sks-keyservers.net hkp://pgp.mit.edu:80"
ENV BUILDOUT=$BUILDOUT \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

WORKDIR /code
ADD apt.txt /code/apt.txt

# setup project timezone, dependencies, user & workdir, gosu
RUN bash -c 'set -ex \
    && : "set correct timezone" \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && : "install packages" \
    && apt-get update -qq \
    && apt-get install -qq -y $(grep -vE "^\s*#" /code/apt.txt  | tr "\n" " ") \
    && apt-get clean all && apt-get autoclean \
    && : "project user & workdir" \
    && useradd -G daemon -ms /bin/bash plone --uid 1000'

# Add here the buildout containing the plone versions link
ADD etc/base.cfg /code/etc/
ADD requirements-dev.txt requirements.txt /code/
RUN bash -c 'set -ex \
    && mkdir -p /code/var/cache/{ui,eggs,develop-eggs,downloads} /data/backup /logs /log \
    && chown plone:plone -R /code /code/var/cache /data /logs /log \
    && cd /code' \
    && gosu plone:plone bash -c 'set -e \
        && log() { echo "$@">&2; } && vv() { log "$@";"$@"; } \
        && python${PY_VER} -m virtualenv venv --unzip-setuptools \
        && . venv/bin/activate \
        && python -m pip install -U pip wheel \
        && python -m pip install -U --no-cache-dir -r ./requirements.txt \
        && if [[ -n "$BUILD_DEV" ]];then \
           python -m pip install -U --no-cache-dir \
           -r ./requirements-dev.txt;fi \
        && touch match.cfg && buildouts="$(find *cfg  etc/ -name "*cfg" -type f 2>/dev/null)" \
        && egrep "dist.plone.org/release.*versions.cfg" $buildouts \
           | sed -re "s|.*release/([^/]+)/.*|\1|" | head -n1 > PLONE_VERSION \
        && export PLONE_VERSION=$(cat PLONE_VERSION)\
        && export PLONE_VERSION_1=$(echo $PLONE_VERSION_1 | sed -re "s/\.[^.]$//g") \
        && export PLONE_VERSION=$(cat PLONE_VERSION)\
        && export PLONE_VERSION_1=$(echo $PLONE_VERSION | sed -re "s/\.[^.]$//g") \
        && : download unversal installer to grab its cache speeding up installs \
        && installer_url="https://launchpad.net/plone/${PLONE_VERSION_1}/${PLONE_VERSION}/+download/Plone-${PLONE_VERSION}-UnifiedInstaller.tgz" \
        && cd var/cache/ui && vv curl -sSLO "$installer_url" \
        && vv tar xf $(ls) && vv tar xf */*/*cache.tar.bz2 -C .. --strip-components=1 \
        && cd ../../.. && rm -rf var/cache/ui \
        '

ADD buildout.cfg buildout-prod.cfg setup.cfg setup.py /code/
ADD etc /code/etc/
ADD src /code/src/
ADD www /code/www/
RUN bash -c 'set -ex \
    && chown -R plone:plone /code/{etc,src,www} /code/*.{py,txt,cfg} \
    && cd /code' \
    && gosu plone:plone bash -c 'set -e \
        && log() { echo "$@">&2; } && vv() { log "$@";"$@"; } \
        && . venv/bin/activate \
        && reqs="$(find requirements* $BUILDOUT      -type f 2>/dev/null)" \
        && buildouts="$(find *cfg  etc/ -name "*cfg" -type f 2>/dev/null)" \
        && echo found requirements: $(echo $reqs|sed "s/ buildout.cfg//g")>&2 \
        && echo found buildouts: $buildouts>&2 \
        && sver=$(egrep -i "^setuptools\s*=="  $reqs|sed -re "s/.*==[ ]*([^ ])/\1/g"|sort -V|tail -n1 ) \
        && bver=$(egrep -i "^zc.buildout\s*==" $reqs|sed -re "s/.*==[ ]*([^ ])/\1/g"|sort -V|tail -n1 ) \
        && if [[ -z $sver ]];then \
             sver=$(egrep -i "^setuptools\s*=" $buildouts|sed -re "s/.*=[ ]*([^ ])/\1/g"|sort -V|tail -n1  ) \
             else echo "Using setuptools version from requirements" >&2; \
            fi \
         && if [[ -z $bver ]];then \
             bver=$(egrep -i "^zc.buildout\s*=" $buildouts|sed -re "s/.*=[ ]*([^ ])/\1/g"|sort -V|tail -n1 )\
             else echo "Using buildout version from requirements" >&2; \
            fi \
         && echo "Using setuptools version: $sver" >&2 \
         && echo "Using buildout version: $bver" >&2 \
         && sed -i -re "s/(^setuptools[ ]+=).*/\1 $sver/g" $buildouts \
         && sed -i -re "s/(^zc.buildout[ ]+=).*/\1 $bver/g" $buildouts \
         && cp etc/sys/settings-local-docker.cfg etc/sys/settings-local.cfg \
         && : configuration for lxml support \
         && export XML2_CONFIG=xml2-config XSLT_CONFIG=xslt-config \
		 && : for wheel support, remove cached dists that would hide wheel releases \
 		 && find var/cache/downloads/dist/ -name "*tar*" -or -name "*zip*" \
            | sort | xargs rm -fv \
         && vv buildout bootstrap && vv bin/buildout -N -c $BUILDOUT \
         && rm -rf var/cache/downloads/dist \
          '
ADD products /code/products/
ADD \
    local/plone-deploy-common/prod/init.sh \
    local/plone-deploy-common/prod/docker-initialize.py \
    /code/init/
WORKDIR /code
ENTRYPOINT ["/code/init/init.sh"]
CMD []
