import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {createLibraryHarness,nodes} from './helpers/library-render-harness.mjs';

const source = 'import React from "react";\n'+readFileSync(new URL('../src/windows/RecordingMicrophoneSelect.tsx',import.meta.url),'utf8');
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
const flush=async()=>{await Promise.resolve();await Promise.resolve();};
const choiceNode=tree=>nodes(tree).find(node=>node?.type==='choice');

test('microphone selection loads on demand, enables the selected input, and preserves recording settings',async()=>{
  const read=deferred(),changes=[];let calls=0;
  const h=createLibraryHarness({listMicrophoneDevices:()=>{calls++;return read.promise;}},source,
    {modules:{'../components/ChoiceSelect':{ChoiceSelect:'choice'}}});
  const props={options:{outputFormat:'mp4',usesCountdown:false,capturesSystemAudio:true,capturesMicrophone:false,showsCursor:true,highlightsClicks:true},disabled:false,onChange:next=>changes.push(next)};
  const c=h.mount('default',props);let menu=choiceNode(c.render());
  assert.equal(calls,0,'no device query until user opens the menu');
  menu.props.onOpen();assert.equal(choiceNode(c.render()).props.menuStatus,'Loading microphones…');
  read.resolve([{id:'usb',name:'USB microphone'}]);await flush();menu=choiceNode(c.render());
  assert.deepEqual(menu.props.options.map(o=>o.value),['','usb']);
  menu.props.onChange('usb');assert.deepEqual(changes[0],{...props.options,usesCountdown:true,capturesMicrophone:true,microphoneDeviceId:'usb'});
  menu.props.onChange('');assert.equal(changes[1].microphoneDeviceId,null);
  c.unmount();
});

test('late microphone enumeration cannot replace a newer list, and missing selections remain explicit',async()=>{
  const requests=[deferred(),deferred()];let calls=0;
  const h=createLibraryHarness({listMicrophoneDevices:()=>requests[calls++].promise},source,
    {modules:{'../components/ChoiceSelect':{ChoiceSelect:'choice'}}});
  const c=h.mount('default',{options:{microphoneDeviceId:'removed'},disabled:false,onChange(){throw new Error('must not silently choose default');}});
  choiceNode(c.render()).props.onOpen();choiceNode(c.render()).props.onOpen();
  requests[1].resolve([{id:'current',name:'Current device'}]);await flush();
  requests[0].resolve([{id:'stale',name:'Old device'}]);await flush();
  const menu=choiceNode(c.render());assert.deepEqual(menu.props.options.map(o=>o.value),['','current']);
  assert.equal(menu.props.value,'removed');assert.equal(menu.props.menuStatus,'Selected microphone is unavailable');c.unmount();
});

test('device menu retains keyboard focus after the focused device disappears and Escape restores its trigger',()=>{
  const changes=[],focused=[];
  const selectSource='import React from "react";\n'+readFileSync(new URL('../src/components/ChoiceSelect.tsx',import.meta.url),'utf8');
  const h=createLibraryHarness({},selectSource,{modules:{'./ChoiceSelect.css':{},'lucide-react':{Check:'check',ChevronDown:'chevron'}},attachRef(node){
    if(node.props.ref && node.props.className?.startsWith('kiri-choice-trigger'))node.props.ref.current={focus(){focused.push('trigger');},getBoundingClientRect(){return {left:250,top:210,bottom:240,width:24};},contains(){return false;}};
    if(node.props.role==='listbox')node.props.ref.current={contains(){return false;},querySelectorAll(){return nodes(node).filter(n=>n?.props?.role==='option').map(n=>({focus(){focused.push(n.props.children[0].props.children[0].props.children[0]);}}));}};
  }});
  h.window.innerWidth=320;h.window.innerHeight=360;
  const props={value:'c',label:'Choose microphone',options:['a','b','c'].map(value=>({value,label:value})),onChange:v=>changes.push(v)};
  const c=h.mount('ChoiceSelect',props);nodes(c.render()).find(n=>n?.props?.['aria-haspopup']==='listbox').props.onClick();
  let tree=c.render();assert.equal(focused.at(-1),'c');
  tree=c.render({...props,options:props.options.slice(0,2)});assert.equal(focused.at(-1),'a');
  let menu=nodes(tree).find(n=>n?.props?.role==='listbox');
  const event=key=>({key,preventDefault(){},stopPropagation(){}});
  menu.props.onKeyDown(event('Enter'));assert.deepEqual(changes,['a']);assert.equal(focused.at(-1),'trigger');
  nodes(c.render()).find(n=>n?.props?.['aria-haspopup']==='listbox').props.onClick();
  menu=nodes(c.render()).find(n=>n?.props?.role==='listbox');menu.props.onKeyDown(event('Escape'));
  assert.equal(focused.at(-1),'trigger');assert.ok(!nodes(c.render()).some(n=>n?.props?.role==='listbox'));c.unmount();
});

test('overlay capture-phase Escape yields to an open microphone menu',()=>{
  const overlay=readFileSync(new URL('../src/windows/OverlayWindow.tsx',import.meta.url),'utf8');
  const code=overlay.slice(overlay.indexOf('    const onEscape = (e: KeyboardEvent) => {'),overlay.indexOf('    window.addEventListener("keydown", onEscape, true);'));
  let cancelled=0,open=true;
  const body=code.replace('const onEscape = (e: KeyboardEvent)', 'const onEscape = (e)')+'return onEscape;';
  const handler=new Function('isTextComposition','document','Element','completionLock','phaseRef','canvasRef','cancel','closeQr',body)(
    ()=>false,{querySelector:()=>open?{}:null},class {},{locked:false},{current:'record-options'},{current:null},()=>cancelled++,()=>{});
  handler({key:'Escape',target:null,preventDefault(){throw new Error('menu must receive escape');},stopImmediatePropagation(){}});
  assert.equal(cancelled,0);open=false;
  handler({key:'Escape',target:null,preventDefault(){},stopImmediatePropagation(){}});assert.equal(cancelled,1);
});
