import re
import uuid

def generate_uuid():
    return uuid.uuid4().hex[:24].upper()

with open('leanring-buddy.xcodeproj/project.pbxproj', 'r') as f:
    content = f.read()

files_to_add = ["LocalTTSClient.swift", "WebSearchClient.swift", "KokoroTTSClient.swift"]

new_build_files = []
new_file_refs = []
new_group_children = []

for f in files_to_add:
    if f not in content:
        file_ref_id = generate_uuid()
        build_file_id = generate_uuid()
        
        # File ref
        new_file_refs.append(f'\t\t{file_ref_id} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
        
        # Build file
        new_build_files.append(f'\t\t{build_file_id} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {f} */; }};')
        
        # Group child
        new_group_children.append(f'\t\t\t\t{file_ref_id} /* {f} */,')
        
        # Inject into sources
        content = re.sub(r'(28F22CBB2F56440300A0FC59 \/\* Sources \*\/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = \()', rf'\1\n\t\t\t\t{build_file_id} /* {f} in Sources */,', content)

if not new_build_files:
    print("Nothing to add.")
    exit(0)

# Create a manual PBXGroup and inject into the root group (28F22CB62F56440300A0FC59)
manual_group_id = generate_uuid()
manual_group_str = f"""\t\t{manual_group_id} /* Manually Added Files */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(new_group_children)}
\t\t\t);
\t\t\tname = "Manually Added Files";
\t\t\tpath = "leanring-buddy";
\t\t\tsourceTree = "<group>";
\t\t}};"""

# Insert manual_group_id into root group
content = re.sub(r'(28F22CB62F56440300A0FC59 = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \()', rf'\1\n\t\t\t\t{manual_group_id} /* Manually Added Files */,', content)

# Inject PBXGroup
content = re.sub(r'(/\* Begin PBXGroup section \*/\n)', r'\1' + manual_group_str + '\n', content)

# Inject PBXBuildFile
content = re.sub(r'(/\* Begin PBXBuildFile section \*/\n)', r'\1' + '\n'.join(new_build_files) + '\n', content)

# Inject PBXFileReference
content = re.sub(r'(/\* Begin PBXFileReference section \*/\n)', r'\1' + '\n'.join(new_file_refs) + '\n', content)

with open('leanring-buddy.xcodeproj/project.pbxproj', 'w') as f:
    f.write(content)
print("Patched successfully")
