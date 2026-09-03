#!/usr/bin/env python3
"""Fix block-scope extern in task_mmu.c for ThinLTO+CFI compatibility.

The NoMount Suite integration patch adds:
    { extern void vfs_map_meta_override(const struct inode *,
                        dev_t *, unsigned long *);
      vfs_map_meta_override(inode, &dev, &ino); }

With CONFIG_LTO_CLANG_THIN + CONFIG_CFI_CLANG this generates GOT/PLT
entries that ld.lld rejects ("Unexpected GOT/PLT entries detected!").

This script replaces the block-scope extern with a direct call and adds
a file-scope extern declaration before show_map_vma().
"""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'fs/proc/task_mmu.c'
content = open(path).read()

pattern = (
    r'\{\s*extern\s+void\s+vfs_map_meta_override\s*\([^)]*\)\s*;'
    r'\s*vfs_map_meta_override\s*\(\s*inode\s*,\s*&dev\s*,\s*&ino\s*\)\s*;\s*\}'
)
content, count = re.subn(pattern, 'vfs_map_meta_override(inode, &dev, &ino);',
                         content, flags=re.DOTALL)
if count == 0:
    print('ERROR: block-scope extern not found in task_mmu.c', file=sys.stderr)
    sys.exit(1)

marker = 'show_map_vma('
idx = content.find(marker)
if idx == -1:
    print('ERROR: show_map_vma not found', file=sys.stderr)
    sys.exit(1)

decl = ('#ifdef CONFIG_NOMOUNT\n'
        'extern void vfs_map_meta_override(const struct inode *, dev_t *, unsigned long *);\n'
        '#endif\n\n')
content = content[:idx] + decl + content[idx:]
open(path, 'w').write(content)
print(f'Fixed task_mmu.c: block-scope extern removed ({count}), file-scope extern added')
