"""Generate synthetic bars and tones with a locally installed FFmpeg. No remote media."""
from pathlib import Path
import json, subprocess, sys

out = Path(sys.argv[1] if len(sys.argv)>1 else 'decoder-fixtures').resolve()
out.mkdir(parents=True, exist_ok=True)
def run(*args):
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y',*map(str,args)], check=True)
base=out/'bars.mp4'
run('-f','lavfi','-i','testsrc2=size=640x360:rate=24','-t','14',
    '-c:v','libx264','-preset','veryfast','-pix_fmt','yuv420p','-an',base)
cases=[]
for codec, name, ext in [('aac','aac','mp4'),('ac3','ac3','mkv'),('eac3','eac3','mkv'),
                         ('dca','dts','mkv'),('truehd','truehd','mkv'),('flac','flac','mkv'),
                         ('alac','alac','mp4'),('libopus','opus','mkv'),('truehd','truehd6','mkv')]:
    path=out/('h264-'+name+'.'+ext)
    run('-i',base,'-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','14',
        '-map','0:v','-map','1:a','-c:v','copy','-c:a',codec,'-ac','6' if name=='truehd6' else '2','-strict','-2',path)
    cases.append({'file':path.name,'mode':2,'audio':'ffmpeg','video':False})
for codec,name,options in [('libaom-av1','av1',['-cpu-used','8','-crf','45','-row-mt','1']),
                           ('libvpx-vp9','vp9',['-deadline','realtime','-cpu-used','6','-crf','40','-b:v','0'])]:
    path=out/(name+'-opus.mkv')
    run('-i',base,'-f','lavfi','-i','sine=frequency=660:sample_rate=48000','-t','14',
        '-map','0:v','-map','1:a','-c:v',codec,*options,'-threads','2',
        '-c:a','libopus','-ac','2',path)
    cases.append({'file':path.name,'mode':2,'audio':'ffmpeg','video':'libgav1' if name=='av1' else 'libvpx'})
cases.extend([{'file':'h264-aac.mp4','mode':0,'video':False},
              {'file':'h264-alac.mp4','mode':0,'audio':'ffmpeg','video':False},
              {'file':'av1-opus.mkv','mode':0,'video':'libgav1'},
              {'file':'h264-aac.mp4','mode':1,'video':False},
              {'file':'vp9-opus.mkv','mode':0,'video':'libvpx'},
              {'file':'h264-ac3.mkv','mode':3,'audio':'ffmpeg','video':False}])
run('-i',out/'h264-ac3.mkv','-i',out/'h264-aac.mp4','-map','0:v','-map','0:a','-map','1:a','-c','copy','-disposition:a:0','0','-disposition:a:1','0',out/'h264-two-audio.mkv')
cases.extend([{'file':'h264-ac3.mkv','mode':0,'software_audio':True,'audio':'ffmpeg'},
              {'file':'h264-ac3.mkv','mode':1,'software_audio':True,'audio':'ffmpeg'},
              {'file':'h264-two-audio.mkv','mode':0,'prefer_aac':True,'audio_mime':'audio/mp4a-latm'}])
(out/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
print(f'Generated {len(cases)} cases in {out}')
