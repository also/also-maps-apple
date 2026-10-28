const fs=require('fs'), path=require('path');
const sharp=require('sharp');
const root=path.resolve(__dirname, '../..');
const original=fs.readFileSync(root+'/docs/branding/tile-icon.svg','utf8');
const paths=[...original.matchAll(/<path d="([^"]+)"\/>/g)].map(m=>m[1]).slice(1);
if(paths.length!==3) throw Error('Expected three building paths');
const front=`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 128 128"><g fill="none" stroke="#303a31" stroke-width="2.2" stroke-linejoin="round">${paths.map(d=>`<path d="${d}"/>`).join('')}</g></svg>`;
const back='<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><path fill="#dce1d5" d="M0 0H1024V1024H0Z"/></svg>';
const info={author:'xcode',version:1};
function json(p,v){fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,JSON.stringify(v,null,2)+'\n');}
(async()=>{const catalog=root+'/Sources/VisionIcon.xcassets'; const stack=catalog+'/AppIcon.solidimagestack';json(catalog+'/Contents.json',{info});json(stack+'/Contents.json',{info,layers:[{filename:'Front.solidimagestacklayer'},{filename:'Back.solidimagestacklayer'}]});
for(const [name,svg] of [['Front',front],['Back',back]]){const layer=stack+'/'+name+'.solidimagestacklayer';json(layer+'/Contents.json',{info});json(layer+'/Content.imageset/Contents.json',{info,images:[{idiom:'vision',scale:'2x',filename:'Icon.png'}]});let image=sharp(Buffer.from(svg));if(name==='Back')image=image.flatten({background:'#dce1d5'});await image.png().toFile(layer+'/Content.imageset/Icon.png');}
fs.writeFileSync(root+'/docs/branding/vision-icon.svg',front.replace('<g ', '<path fill="#dce1d5" d="M0 0H128V128H0Z"/><g '));})().catch(error => { console.error(error); process.exitCode = 1; });
