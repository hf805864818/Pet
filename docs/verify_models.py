#!/usr/bin/env python3
import zipfile,json,sys,hashlib
p=sys.argv[1]
with zipfile.ZipFile(p) as z:
 matches=[n for n in z.namelist() if n.endswith('live/model.json')]
 assert len(matches)==1, f"Expected one live/model.json, found {len(matches)}"
 d=json.loads(z.read(matches[0]));models=d['models']; required=['maid','cape','crew','sailor','deepsea-winter-prototype']
 for key in required:
  assert key in models, f"missing {key}"
  assert isinstance(models[key].get('parts'),list)
  assert isinstance(models[key].get('deformers'),dict)
  print(key, len(models[key]['parts']), len(models[key]['deformers']))
 print('PASS: 5 models present in resource ZIP; NOT a device runtime test')
