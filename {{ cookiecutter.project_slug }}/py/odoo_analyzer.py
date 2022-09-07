from functools import cached_property

from odoo.modules import initialize_sys_path
initialize_sys_path()

def this_ref(*path):
    from os.path import dirname, realpath, join
    THIS_PATH = dirname(realpath(__file__))
    return join(THIS_PATH, *path)

def odoo_ref(*path):
    from os.path import dirname, realpath, join
    import odoo
    ODOO_PATH = dirname(realpath(odoo.__file__))
    return join(ODOO_PATH, '..', *path)

def load_config(filename=None):
    if filename is None: filename = odoo_ref('odoo.conf')
    from odoo.tools import config
    config.parse_config([
        '--load-language', "",
        '-c', filename,
    ])
    return config

def is_addon_module(m):
    from types import ModuleType
    if not isinstance(m, ModuleType): return False
    return (m.__package__ or '').startswith('odoo.addons.')

def is_model_class(c):
    from inspect import isclass
    from odoo.models import Model, TransientModel
    return isclass(c) and issubclass(c, (Model, TransientModel))

def iter_addon_model_classes(m):
    prefix = m.__package__
    yield from _iter_addon_model_classes(set(), (prefix + '.'), m)

def _iter_addon_model_classes(did, prefix, m):
    for k in dir(m):
        v = getattr(m, k)
        if is_addon_module(v):
            if not v.__package__.startswith(prefix): continue
            if v in did: continue
            did.add(v)
            yield from _iter_addon_model_classes(did, prefix, v)
        elif is_model_class(v):
            if not v.__module__.startswith(prefix): continue
            if v in did: continue
            did.add(v)
            yield v

class AddonInfo:
    analyzer = None
    store = None
    name = None
    addon_module_path = None
    _module = None
    _models = None
    def __init__(self, analyzer, path):
        from os.path import normpath, basename, split
        addon_module_path = normpath(path)
        (store, name) = split(addon_module_path)
        self.analyzer = analyzer
        self.store = store
        self.name = name
        self.addon_module_path = addon_module_path
    def __repr__(self):
        return f'<{self.name}>'
    @cached_property
    def manifest(self):
        from os.path import isfile, join
        f = join(self.addon_module_path, '__manifest__.py')
        return eval(open(f, encoding='utf-8').read())
    @property
    def module(self):
        self.load()
        return self._module
    @property
    def models(self):
        self.load()
        return self._models
    @property
    def loaded(self):
        return self._module is not None
    def _done_load(self, module):
        self._module = module
        self._models = [ModelInfo(self, c) for c in iter_addon_model_classes(module)]
    def load(self):
        if self.loaded: return
        self.analyzer._load_addon(self)
        assert self._module is not None
        assert self._models is not None
    def iter_depends(self):
        for n in self.manifest.get('depends', []):
            d = self.analyzer.find_addon(n)
            if d is None: continue
            yield d

def get_model_name_from_class(c):
    n = getattr(c, '_name')
    if n: return n
    n = getattr(c, '_inherit')
    if isinstance(n, list) and len(n) == 1: n = n[0]
    if isinstance(n, str): return n
    return None

def is_new_model(c):
    inherit = getattr(c, '_inherit', [])
    return (not inherit) or (c._name not in inherit)

def iter_model_fields(m):
    from odoo.fields import Field
    for (k, v) in m.__dict__.items():
        if isinstance(v, Field): yield (k, v)

def iter_model_functions(m):
    from types import FunctionType
    for (k, v) in m.__dict__.items():
        if isinstance(v, FunctionType): yield (k, v)

class ModelInfo:
    addon             = None
    model_class       = None
    name              = cached_property(lambda self: get_model_name_from_class(self.model_class))
    is_new            = cached_property(lambda self: is_new_model(self.model_class))
    defined_fields    = cached_property(lambda self: list(iter_model_fields(self.model_class)))
    defined_functions = cached_property(lambda self: list(iter_model_functions(self.model_class)))
    def __init__(self, addon, model_class):
        self.addon             = addon
        self.model_class       = model_class
    def __repr__(self):
        return f'[{self.name}]'

class Analyzer:
    SKIPPINGS = ['hw_drivers', 'hw_escpos', 'hw_posbox_homepage', 'hw_l10n_eg_eta', 'l10n_eg_edi_eta']
    def __init__(self, configfile=None):
        self.config = load_config(configfile)
        self.addons = {}
    @cached_property
    def addon_store_paths(self):
        return self.config.options.get('addons_path').split(',')
    def try_get_addon_from_path(self, path):
        from os.path import isfile, join
        if not isfile(join(path, '__manifest__.py')): return None
        a = AddonInfo(self, path)
        if a.name in self.SKIPPINGS: return None
        elif a.name in self.addons:
            existing = self.addons[a.name]
            if a.addon_module_path != existing.addon_module_path:
                raise Exception(f'Duplicate addon name: "{a.addon_module_path}" vs "{existing.addon_module_path}"')
            return existing
        else:
            self.addons[a.name] = a
            return a
    def iter_addons(self, store_filter=None):
        import os
        store_paths = self.addon_store_paths
        if store_filter is not None: store_paths = [p for p in store_paths if store_filter(p)]
        for store in store_paths:
            with os.scandir(store) as addons:
                for p in addons:
                    addon = self.try_get_addon_from_path(p.path)
                    if addon is not None:
                        yield addon
    def find_addon(self, name):
        from os.path import join
        for p in self.addon_store_paths:
            addon_path = join(p, name)
            a = self.try_get_addon_from_path(addon_path)
            if a is not None: return a
        return None
    def _recursive_load_addon(self, did, addon):
        if addon.name in did: return
        if not addon.loaded:
            did.add(addon.name)
            self._recursive_load_depends(did, addon)
            import importlib
            m = importlib.import_module('odoo.addons.' + addon.name)
            addon._done_load(m)
    def _recursive_load_depends(self, did, addon):
        for d in addon.iter_depends():
            self._recursive_load_addon(did, d)
    def _load_addon(self, addon):
        self._recursive_load_addon(set(), addon)
    def find_duplicate_addons(self):
        addons = {}
        for addon in self.iter_addons():
            addons.setdefault(addon.name, []).append(addon.store)
        duplicated = { k:v for (k,v) in addons.items() if len(v) > 1 }
        return duplicated
