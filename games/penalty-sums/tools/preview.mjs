// Debug helper: composite the prepped sprites onto a checkerboard so any
// leftover key colour or edge fringe is obvious. Not part of the build.
import fs from 'node:fs'; import path from 'node:path'; import {PNG} from 'pngjs';
import {fileURLToPath} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const OUT=path.join(here,'..','public','assets');
const names=process.argv.slice(2);
const W=1200,H=760; const sheet=new PNG({width:W,height:H});
for(let y=0;y<H;y++)for(let x=0;x<W;x++){const i=(y*W+x)*4;const c=((x>>4)+(y>>4))%2?200:120;sheet.data[i]=c;sheet.data[i+1]=c;sheet.data[i+2]=c;sheet.data[i+3]=255;}
let ox=4;
for(const n of names){
  const p=PNG.sync.read(fs.readFileSync(path.join(OUT,n+'.png')));
  const f=Math.min(1,(H-8)/p.height, 560/p.width);
  const dw=Math.round(p.width*f),dh=Math.round(p.height*f);
  for(let y=0;y<dh;y++)for(let x=0;x<dw;x++){
    const si=((Math.floor(y/f))*p.width+Math.floor(x/f))*4;
    const dx=ox+x,dy=4+y; if(dx>=W||dy>=H)continue;
    const di=(dy*W+dx)*4; const a=p.data[si+3]/255;
    sheet.data[di]=Math.round(sheet.data[di]*(1-a)+p.data[si]*a);
    sheet.data[di+1]=Math.round(sheet.data[di+1]*(1-a)+p.data[si+1]*a);
    sheet.data[di+2]=Math.round(sheet.data[di+2]*(1-a)+p.data[si+2]*a);
  }
  ox+=dw+8;
}
const sp=process.env.PREVIEW_OUT||'/tmp/preview.png';
fs.writeFileSync(sp,PNG.sync.write(sheet)); console.log(sp);
