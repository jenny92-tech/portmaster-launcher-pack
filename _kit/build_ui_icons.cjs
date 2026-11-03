#!/usr/bin/env node
// INPUT:  Sharp and pinned _kit/love/icons SVGs/upstream manifest
// OUTPUT: Antialiased icon atlas.png and its generated layout.lua
// POS:    Offline rasterization of official Fluent icons for pixel-sized UI draws
const fs=require('fs');
const path=require('path');
const crypto=require('crypto');
const sharp=require('sharp');
const root=path.join(__dirname,'love/icons');
const manifest=JSON.parse(fs.readFileSync(path.join(root,'upstream.json'),'utf8'));
const {min_size:min,max_size:max,padding:pad,supersampling}=manifest.raster;
const rowHeight=max+pad*2;
const width=Array.from({length:max-min+1},(_,i)=>min+i+pad*2).reduce((a,b)=>a+b,0);
const height=rowHeight*manifest.icons.length;

async function build(){
    const composites=[];
    const names=[];
    for(let row=0;row<manifest.icons.length;row++){
        const icon=manifest.icons[row];
        const bytes=fs.readFileSync(path.join(root,icon.file));
        if(crypto.createHash('sha256').update(bytes).digest('hex')!==icon.sha256){
            throw new Error('Source digest mismatch: '+icon.name);
        }
        const svg=Buffer.from(bytes.toString().replace(/fill="(?!none)[^"]+"/g,'fill="'+manifest.raster.color+'"'));
        let x=0;
        for(let size=min;size<=max;size++){
            const large=await sharp(svg,{density:72*supersampling}).resize(size*supersampling,size*supersampling).png().toBuffer();
            const input=await sharp(large).resize(size,size,{kernel:'lanczos3'}).png().toBuffer();
            composites.push({input,left:x+pad,top:row*rowHeight+pad});
            x+=size+pad*2;
        }
        names.push('        '+icon.name+'='+row+',');
    }
    await sharp({create:{width,height,channels:4,background:{r:0,g:0,b:0,alpha:0}}})
        .composite(composites).png().toFile(path.join(root,'atlas.png'));
    const lua=[
        '-- INPUT:  Pinned Fluent SVGs and upstream.json via _kit/build_ui_icons.cjs',
        '-- OUTPUT: Physical-size icon atlas geometry and semantic row indices',
        '-- POS:    Generated icon layout; rebuild rather than edit by hand',
        'return {',
        '    width='+width+',height='+height+',min_size='+min+',max_size='+max+',padding='+pad+',row_height='+rowHeight+',',
        '    names={',...names,'    },','}',
    ].join('\n')+'\n';
    fs.writeFileSync(path.join(root,'layout.lua'),lua);
    console.log('Built '+manifest.icons.length+' Fluent icons at '+min+'–'+max+' px: '+width+'×'+height);
}
build().catch(error=>{console.error(error.message);process.exitCode=1;});
