#!/usr/local/bin/python
# stolen and credits from from library/plone docker image
import re
import os
import warnings
warnings.simplefilter('always', DeprecationWarning)

PREFIX = 'PLONE__'
KNOBS = {
    'root': os.environ.get('PLONE__PROJECT_DIR', os.path.abspath(os.getcwd())),
    'instance': 'instance',
    'zope_conf': "{root}/parts/{instance}/etc/zope.conf",
    'custom_conf': "{root}/custom.cfg",
    'zeopack_conf': "{root}/bin/zeoserver-zeopack",
    'zeoserver_conf': "{root}/parts/zeoserver/etc/zeo.conf",
    'zopelogpath': "/logs/{instance}.log",
    'zeo_address': "zeo:8100",
    'zeo_read_only': "false",
    'zeo_client_read_only_fallback': "false",
    'zeo_shared_blob_dir': "off",
    'zeo_storage': "1",
    'zeo_blobdir': '/data/blobstorages/Data',
    'zeo_client_cache_size': "128MB",
}


class Environment(object):
    """ Configure container via environment variables
    """
    def __init__(self, env=os.environ):
        self.env = env
        order = ['root', 'instance']
        for i in order + [a for a in KNOBS if a not in order]:
            val = self.env.get('{0}{1}'.format(PREFIX, i.upper()), KNOBS[i])
            if i != 'root':
                val = val.format(**KNOBS)
            setattr(self, i.lower(), val)

    def zeoclient(self):
        """ ZEO Client
        """
        if not self.zeo_address:
            return

        zeo_conf = ZEO_TEMPLATE.format(self.__dict__)
        config = ""
        with open(self.zope_conf, "r") as cfile:
            config = cfile.read()

        pattern = re.compile(r"<zeoclient>.+</zeoclient>", re.DOTALL)
        config = re.sub(pattern, zeo_conf, config)

        with open(self.zope_conf, "w") as cfile:
            cfile.write(config)

    def zeopack(self):
        """ ZEO Pack
        """
        server = self.zeo_address
        if not server:
            return

        if ":" in server:
            host, port = server.split(":")
        else:
            host, port = (server, "8100")

        with open(self.zeopack_conf, 'r') as cfile:
            text = cfile.read()
            text = text.replace('address = "8100"', 'address = "%s"' % server)
            text = text.replace('host = "zeo"', 'host = "%s"' % host)
            text = text.replace('port = "8100"', 'port = "%s"' % port)

        with open(self.zeopack_conf, 'w') as cfile:
            cfile.write(text)

    def zeoserver(self):
        """ ZEO Server
        """
        if self.zeo_pack_keep_old.lower() in ("false", "no", "0", "n", "f"):
            with open(self.zeoserver_conf, 'r') as cfile:
                text = cfile.read()
                if 'pack-keep-old' not in text:
                    text = text.replace(
                        '</filestorage>',
                        '  pack-keep-old false\n</filestorage>'
                    )

            with open(self.zeoserver_conf, 'w') as cfile:
                cfile.write(text)

    def sentry(self):
        """Sentry alerting if any
        """
        conf = []
        text = ''
        for i in [
            'dsn', 'release', 'level', 'project', 'environment'
        ]:
            val = self.env.get('PLONE__SENTRY_{0}'.format(i.upper()), '')
            if i == 'dsn' and not val:
                return
            if val:
                conf.append('\n{0} {1}'.format(i, val))
        sconf = '\n'.join(conf)
        if 'dsn' not in sconf:
            return
        sconf = SENTRY_TEMPLATE.format(
            conf=sconf,
            zopelogpath=self.zopelogpath,
            zopeloglevel=self.env.get('PLONE__SENTRY_ZOPELOGLEVEL', 'INFO')
        )
        with open(self.zope_conf, 'r') as cfile:
            text = cfile.read()
            pattern = re.compile(r"<eventlog>.+</eventlog>", re.DOTALL)
            text = re.sub(pattern, sconf, text)
        with open(self.zope_conf, 'w') as cfile:
            cfile.write(text)

    def setup(self, **kwargs):
        # in our setups values are based on DNS
        # and we wont need to replace, everything is already in place
        # in the image
        # self.zeoclient()
        # self.zeopack()
        # self.zeoserver()
        # but we still need to patch sentry conf
        self.sentry()

    __call__ = setup


ZEO_TEMPLATE = """
    <zeoclient>
      read-only {zeo_read_only}
      read-only-fallback {zeo_client_read_only_fallback}
      storage {zeo_storage}
      blob-dir {zeo_blobdir}
      shared-blob-dir {zeo_shared_blob_dir}
      server {zeo_address}
      storage {zeo_storage}
      name zeostorage
      var {root}/parts/{instance}/var
      cache-size {zeo_client_cache_size}
    </zeoclient>
    mount-point /
""".strip()


SENTRY_TEMPLATE = '''
<eventlog>
level {zopeloglevel}
%import raven.contrib.zope
<logfile>
path {zopelogpath}
level {zopeloglevel}
</logfile>
<sentry>
{conf}
</sentry>
</eventlog>
'''


def initialize():
    """ Configure Plone instance as ZEO Client
    """
    environment = Environment()
    environment.setup()


if __name__ == "__main__":
    initialize()
