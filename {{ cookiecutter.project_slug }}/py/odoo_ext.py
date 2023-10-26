# Odoo extra utilities

def this_path(*path):
    from os.path import dirname, normpath, join
    return normpath(join(dirname(__file__), *path))

def base_path(*path):
    return this_path('..', *path)

loaded = False

def load_config(filename=None):
    global loaded
    if loaded: raise Exception('Config is already loaded.')
    from odoo.tools import config
    if filename is None: filename = base_path('odoo.conf')
    config.parse_config(['-c', filename])
    loaded = True

def _create_env(uid, context):
    from odoo import registry
    from odoo.api import Environment
    from odoo.tools import config
    cr = registry(config['db_name']).cursor()
    return Environment(cr, uid, context)

def create_super_env(context=None):
    if not loaded: raise Exception('Config is not loaded yet.')
    from odoo import SUPERUSER_ID
    if context is None: context = {}
    return _create_env(SUPERUSER_ID, context)

def create_env(uid=None, context=None):
    if not loaded: raise Exception('Config is not loaded yet.')
    if uid is None:
        return create_super_env(context)
    else:
        if context is None:
            super_env = create_super_env()
            context = super_env['res.users'].browse(uid).context_get()
        return _create_env(uid, context)
