# Odoo extra utilities

def odoo_ref(*path):
    from os.path import dirname, realpath, join
    import odoo
    THIS_PATH = dirname(realpath(odoo.__file__))
    return join(THIS_PATH, '..', *path)

def load_config(filename=None):
    if filename is None: filename = odoo_ref('odoo.conf')
    config.parse_config(['-c', filename])

def _create_env(uid, context):
    from odoo import registry
    from odoo.api import Environment
    from odoo.tools import config
    cr = registry(config['db_name']).cursor()
    return Environment(cr, uid, context)

def create_super_env(context=None):
    from odoo import SUPERUSER_ID
    if context is None: context = {}
    return _create_env(SUPERUSER_ID, context)

def create_env(uid=None, context=None):
    if uid is None:
        return create_super_env(context)
    else:
        if context is None:
            superenv = create_super_env()
            context = superenv['res.users'].browse(uid).context_get()
        return _create_env(uid, context)
