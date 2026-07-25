import sys, re

path = r'c:\Users\Administrator\Desktop\wenku8\Re 从零开始的异世界生活.pdf'
with open(path, 'rb') as f:
    data = f.read()

print(f"File size: {len(data)}")
print(f"Header: {data[:50]}")

# Find all objects
idx = 0
objs = {}
while True:
    pos = data.find(b' 0 obj', idx)
    if pos == -1:
        break
    start = pos
    while start > 0 and data[start-1:start] in [b' ', b'\n', b'\r']:
        start -= 1
    num_start = start
    while num_start > 0 and data[num_start-1:num_start].isdigit():
        num_start -= 1
    num = int(data[num_start:start].decode())
    end = data.find(b'endobj', pos)
    if end > 0:
        objs[num] = data[pos:end]
    idx = end + 6 if end > 0 else pos + 1

print(f"Total objects: {len(objs)}")
print(f"Object numbers: {sorted(objs.keys())}")

# Check xref table
xref_pos = data.find(b'\nxref\n')
if xref_pos == -1:
    xref_pos = data.find(b'xref\n')
print(f"\nxref at: {xref_pos}")
if xref_pos > 0:
    print(f"xref content: {data[xref_pos:xref_pos+200]}")

# Check trailer
trailer_pos = data.rfind(b'trailer')
print(f"\ntrailer at: {trailer_pos}")
if trailer_pos > 0:
    print(f"trailer content: {data[trailer_pos:trailer_pos+200]}")

# Check for /Length mismatches
for k in sorted(objs.keys()):
    v = objs[k]
    m = re.search(rb'/Length\s+(\d+)', v)
    if m and b'stream' in v:
        declared_len = int(m.group(1))
        stream_marker = v.find(b'stream\n')
        if stream_marker == -1:
            stream_marker = v.find(b'stream\r\n')
        if stream_marker >= 0:
            if v[stream_marker:stream_marker+8] == b'stream\n':
                sdata_start = stream_marker + 8
            else:
                sdata_start = stream_marker + 9
            stream_end = v.find(b'endstream')
            if stream_end > 0:
                actual_len = stream_end - sdata_start
                if declared_len != actual_len:
                    print(f"!!! LENGTH MISMATCH obj {k}: declared={declared_len} actual={actual_len}")

# Check first few objects
for i in sorted(objs.keys())[:10]:
    content = objs[i].decode('latin-1', errors='replace')
    first_line = content[:content.find('\n')+1].strip() if '\n' in content else content[:100]
    print(f"Obj {i}: {first_line[:120]}")
