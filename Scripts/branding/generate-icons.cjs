const fs = require('fs');
const path = require('path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '../..');
const info = {author:'xcode',version:1};
function json(p, value) { fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,JSON.stringify(value,null,2)+'\n'); }
function project(x,y,z) { const turn=-.16,tilt=.60; const across=x*Math.cos(turn)-z*Math.sin(turn); const depth=x*Math.sin(turn)+z*Math.cos(turn); const scale=71/(1-(depth*Math.cos(tilt)+y*Math.sin(tilt))/14); return [64+across*scale,70+(depth*Math.sin(tilt)-y*Math.cos(tilt))*scale]; }
function d(points,close=true) { return points.map((p,i)=>(i?'L':'M')+project(...p).join(' ')).join(' ')+(close?' Z':''); }
const outline=d([[-.555,0,-.555],[.555,0,-.555],[.555,0,.555],[-.555,0,.555]]);
const tile=d([[-.445,0,-.445],[.445,0,-.445],[.445,0,.445],[-.445,0,.445]]);
const buildings=[[-.20,-.15,.14,.13],[.15,0,.19,.23],[-.05,.20,.11,.17]].map(([x,z,w,h])=>d([[x-w/2,0,z],[x,h,z],[x+w/2,0,z]],false));
const mark=`<g stroke="#303a31" stroke-width="2.2" stroke-linejoin="round" fill="none"><path d="${outline}"/><path d="${tile}" fill="#dce1d5" stroke="none"/>${buildings.map(p=>`<path d="${p}"/>`).join('')}</g>`;
function svg(w,h,bg=true,art=true) { return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${bg?`<path fill="#f3f0e8" d="M0 0H${w}V${h}H0Z"/>`:''}${art?`<g transform="translate(${(w-h)/2} 0) scale(${h/128})">${mark}</g>`:''}</svg>`; }
async function png(p,w,h,bg=true,art=true) { fs.mkdirSync(path.dirname(p),{recursive:true}); let s=sharp(Buffer.from(svg(w,h,bg,art))); if(bg) s=s.flatten({background:'#f3f0e8'}); await s.png().toFile(p); }
(async()=>{
 fs.mkdirSync(root+'/docs/branding',{recursive:true}); fs.writeFileSync(root+'/docs/branding/tile-icon.svg',svg(1024,1024));
 const phone=root+'/SourcesPhone/Assets.xcassets'; json(phone+'/Contents.json',{info});
 await png(phone+'/AppIcon.appiconset/AppIcon.png',1024,1024);
 json(phone+'/AppIcon.appiconset/Contents.json',{images:[{filename:'AppIcon.png',idiom:'universal',platform:'ios',size:'1024x1024'}],info});
 const mac=root+'/SourcesMac/Assets.xcassets'; json(mac+'/Contents.json',{info}); const images=[];
 for(const size of [16,32,128,256,512]) for(const scale of [1,2]) {const filename=`icon-${size}@${scale}x.png`; await png(mac+'/AppIcon.appiconset/'+filename,size*scale,size*scale); images.push({filename,idiom:'mac',size:`${size}x${size}`,scale:`${scale}x`});}
 json(mac+'/AppIcon.appiconset/Contents.json',{images,info});
 const tv=root+'/SourcesTV/Assets.xcassets'; json(tv+'/Contents.json',{info});
 const brand=tv+'/AppIcon.brandassets'; const assets=JSON.parse(fs.readFileSync(brand+'/Contents.json','utf8')).assets.filter(asset=>asset.role!=='primary-app-icon');
 for(const [name,w,h,role] of [['App Icon',400,240,'primary-app-icon'],['App Icon - App Store',1280,768,'primary-app-icon']]) {
   assets.push({filename:name+'.imagestack',idiom:'tv',role,size:`${w}x${h}`});
   const stack=brand+'/'+name+'.imagestack'; json(stack+'/Contents.json',{layers:[{filename:'Front.imagestacklayer'},{filename:'Back.imagestacklayer'}],info});
   for(const layer of ['Front','Back']) {const dir=stack+'/'+layer+'.imagestacklayer';json(dir+'/Contents.json',{info});const imgs=[];
     for(const scale of (w===400?[1,2]:[1])) {const filename=`image@${scale}x.png`;await png(dir+'/Content.imageset/'+filename,w*scale,h*scale,layer==='Back',layer==='Front'); imgs.push({filename,idiom:'tv',scale:`${scale}x`});}
     json(dir+'/Content.imageset/Contents.json',{images:imgs,info});
   }
 }
 json(brand+'/Contents.json',{assets,info});
})().catch(error => { console.error(error); process.exitCode = 1; });
