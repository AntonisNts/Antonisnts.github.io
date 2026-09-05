import fs from 'node:fs'; import {PNG} from 'pngjs';
const src=PNG.sync.read(fs.readFileSync(process.argv[2]));
const [x0,y0,x1,y1,z]=process.argv.slice(4).map(Number);
const w=x1-x0,h=y1-y0;const o=new PNG({width:w*z,height:h*z});
for(let y=0;y<h*z;y++)for(let x=0;x<w*z;x++){
 const sx=x0+Math.floor(x/z), sy=y0+Math.floor(y/z);
 const si=(sy*src.width+sx)*4, di=(y*w*z+x)*4;
 let r=src.data[si],g=src.data[si+1],b=src.data[si+2];
 if((sx%50===0)||(sy%50===0)){r=0;g=0;b=255;}
 if((sx%100===0)||(sy%100===0)){r=255;g=255;b=0;}
 o.data[di]=r;o.data[di+1]=g;o.data[di+2]=b;o.data[di+3]=255;}
fs.writeFileSync(process.argv[3],PNG.sync.write(o));
