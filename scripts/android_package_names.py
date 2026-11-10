"""Clear Android artifact names, with byte-identical aliases for older updaters."""
import hashlib
from pathlib import Path
import re
import shutil


def package_name(version, edition):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?', version):
        raise ValueError('Invalid package version')
    if edition not in ('tv', 'mobile', 'lite'):
        raise ValueError('Unknown Android edition')
    return f'MarcoMovie-{version}-android-{edition}.apk'


def compatibility_alias(package, version, edition):
    package = Path(package)
    if package.name != package_name(version, edition):
        raise ValueError('Package name does not match edition')
    suffix = 'preview' if edition == 'tv' else edition
    alias = package.with_name(f'MarcoMovie-{version}-{suffix}.apk')
    shutil.copyfile(package, alias)
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    if hashlib.sha256(alias.read_bytes()).hexdigest() != digest:
        raise ValueError('Compatibility alias differs from installer')
    alias.with_name(alias.name + '.sha256').write_text(digest + '  ' + alias.name + '\n', encoding='ascii')
    return alias
