(() => {
  'use strict';
  const {metro} = vendetta;
  const RN=metro.common.ReactNative, React=metro.common.React;
  let live=false, report='', busy=false, generation=0;
  const relevant=/voice|audio|microphone|mic(?:input|gain|volume|level|muted|mode)|mediaengine|webrtc|opus|pcm|sample(?:rate|buffer|data)|capture|recording|pitch|formant|equaliz|\beq\b|noise(?:suppression|cancellation)|echoCancellation|automaticGain|inputVolume|inputGain|vad(?:Threshold|Mode)|transportOptions|loopback|dsp|voiceFilter|audioUnit/i;
  const secret=/token|password|credential|authorization|secret|sessionid|cookie|email|phone|userid|channelid|guildid/i;
  const good=k=>typeof k==='string'&&/^[A-Za-z_$][A-Za-z0-9_$.:-]{0,79}$/.test(k)&&!secret.test(k);
  const obj=x=>x!==null&&(typeof x==='object'||typeof x==='function');
  function keys(x){try{return obj(x)?Object.getOwnPropertyNames(x).filter(good):[];}catch(_){return [];}}
  function descriptor(x,k){try{return Object.getOwnPropertyDescriptor(x,k);}catch(_){return undefined;}}
  function value(x,k){const d=descriptor(x,k);return d&&'value'in d?d.value:undefined;}
  function methods(x){const out=new Set();let cur=x;
    for(let i=0;obj(cur)&&cur!==Object.prototype&&cur!==Function.prototype&&i<3;i++){
      for(const k of keys(cur)){const d=descriptor(cur,k);if(d&&typeof d.value==='function'&&k!=='constructor')out.add(k);else if(d&&(d.get||d.set)&&relevant.test(k))out.add(k+' [accessor]');}
      try{cur=Object.getPrototypeOf(cur);}catch(_){break;}
    }return [...out].sort();
  }
  function scanObject(label,x,found,force=false){if(!obj(x))return;const m=methods(x), hits=m.filter(k=>relevant.test(k));
    if((force||hits.length)&&m.length){const selection=force?m:hits;found.add(label+' ['+selection.join(', ')+']');}}
  const names=['DCDVoice','DCDVoiceModule','DCDVoiceEngine','DCDMediaEngine','DCDMediaEngineModule','DCDMedia','DCDAudio','DCDAudioModule','DCDAudioManager','DCDAudioSession','DCDWebRTC','DiscordVoice','DiscordMediaEngine','VoiceModule','VoiceEngine','MediaEngine','AudioModule','AudioManager','AudioSession','WebRTCModule','RNWebRTC','RTCAudioSession','AudioRecorder','AudioProcessing','VoiceProcessing','AudioEngine','NativeAudioModule'];
  const probes=[['setInputVolume'],['getInputVolume'],['setNoiseSuppression'],['setNoiseCancellation'],['setEchoCancellation'],['setAutomaticGainControl'],['getMediaEngine'],['getVoiceEngine'],['setTransportOptions'],['setVoiceFilter'],['getVoiceFilters'],['setVoiceEffect'],['setPitch'],['setAudioPitch'],['setEqualizer'],['setAudioEffect'],['setAudioProcessing'],['setInputGain'],['setAudioInputCallback'],['setAudioCaptureCallback'],['setAudioFrameCallback'],['setAudioPreprocessor'],['processAudioFrame'],['onAudioFrame'],['onAudioData'],['setPcmCallback'],['setMicrophoneVolume'],['setLocalVolume'],['setSelfMute']];
  // Inspect only names and function arity, never audio buffers or property values.
  const candidateMethods=['getMediaEngine','getVoiceEngine','getAudioEngine','getAudioMixerSettings','setAudioMixerSettings','setInputVolume','setInputGain','setInputVolumeScale','setAudioInputInitializationCallback','setOnVoiceCallback','setTransportOptions','connectionInstanceSetTransportOptions','applyMediaFilterSettingsWithCallback','setSidechainCompression','setVoiceProcessingErrorCallback','setVoiceFilter','setVoiceFilters','getVoiceFilters','setVoiceEffect','setPitch','setPitchShift','setAudioPitch','setFormant','setEqualizer','setAudioEffect','setAudioEffects','setAudioProcessing','setAudioInputCallback','setAudioCaptureCallback','setAudioFrameCallback','setAudioPreprocessor','processAudioFrame','onAudioFrame','onAudioData','setPcmCallback','setAudioSamplesCallback','setLocalAudioCallback','setAudioSink','setAudioSource','setAudioProcessor','setAudioProcessingCallback','setAudioTransform','setMicGain','setNoiseSuppression','setNoiseCancellation','setAutomaticGainControl','setEchoCancellation','getAudioSubsystem','getInputDevices'];
  function describe(label,x){
    if(!obj(x))return label+' -> '+(x===null?'null':typeof x);
    const names=new Set(), properties=new Set();let cur=x;
    for(let i=0;obj(cur)&&cur!==Object.prototype&&cur!==Function.prototype&&i<5;i++){
      for(const k of keys(cur)){const d=descriptor(cur,k);if(!d||k==='constructor')continue;
        if(typeof d.value==='function')names.add(k+'('+d.value.length+')');
        else if(relevant.test(k))properties.add(k+(d.get||d.set?' [accessor]':' [property]'));
      }
      try{cur=Object.getPrototypeOf(cur);}catch(_){break;}
    }
    // Lazy native bridge proxies may not enumerate their methods.
    for(const k of candidateMethods){try{const f=x[k];if(typeof f==='function'&&![...names].some(n=>n.startsWith(k+'(')))names.add(k+'('+f.length+')');}catch(_){}}
    return label+'\nMethods: '+([...names].sort().join(', ')||'none visible')+'\nAudio-related property names: '+([...properties].sort().join(', ')||'none visible');
  }
  const wait=()=>new Promise(resolve=>setTimeout(resolve,0));
  async function scan(){
    if(busy||!live)return;busy=true;const id=++generation;const native=new Set(),modules=new Set(),foundQueries=new Set(),info=[];
    const alive=()=>live&&id===generation;
    try{
      const n=RN.NativeModules;
      let listed=keys(n).filter(k=>relevant.test(k));info.push('NativeModules matching names: '+(listed.join(', ')||'none enumerable'));
      // Explicit module lookups may initialize a lazy bridge wrapper. Never call audio methods.
      for(const k of [...new Set([...listed,...names])]){if(!alive())return;try{const x=n?.[k];if(obj(x)){native.add(k+' (NativeModules)');scanObject(k,x,native,true);}}catch(_){} }
      const turbo=RN.TurboModuleRegistry;
      info.push('TurboModuleRegistry.get: '+(typeof turbo?.get==='function'?'available':'not exposed'));
      // Try names suggested by native modules and the known audio-related candidates only.
      if(typeof turbo?.get==='function')for(const k of [...new Set([...listed,...names])]){if(!alive())return;try{const x=turbo.get(k);if(obj(x)){native.add(k+' (TurboModuleRegistry)');scanObject(k,x,native,true);}}catch(_){} }
      await wait(); if(!alive())return;
      let r;try{r=typeof globalThis!=='undefined'?globalThis.__r:undefined;}catch(_){}
      let registry;try{if(typeof r?.getModules==='function')registry=r.getModules();}catch(_){}
      let entries=[];try{if(registry instanceof Map)entries=Array.from(registry.entries());else if(obj(registry))entries=Object.keys(registry).map(k=>[k,registry[k]]);}catch(_){}
      info.push('Metro registry entries: '+entries.length);
      let examined=0;
      for(let i=0;i<entries.length;i++){
        if(!alive())return;
        const [mid,mod]=entries[i];if(value(mod,'isInitialized')===true){
          const exp=value(value(mod,'publicModule'),'exports');
          if(obj(exp)){
            examined++; const label='Metro '+(typeof mid==='number'||/^\d+$/.test(String(mid))?mid:'?');
            scanObject(label,exp,modules);
            // Inspect existing exports only, not arbitrary nested application state.
            for(const k of keys(exp).slice(0,90)){
              const v=value(exp,k);
              if((k==='default'||relevant.test(k))&&obj(v))scanObject(label+'.'+k,v,modules,relevant.test(k));
              if(modules.size>=160)break;
            }
          }
        }
        if(modules.size>=160){info.push('Metro results capped at 160');break;}
        if(i%150===149)await wait();
      }
      info.push('Initialized modules examined: '+examined);
      // Targeted public Vendetta lookups supplement non-enumerable Metro registries.
      // Each lookup can initialize lazy JS modules; only method names are retained.
      for(const props of probes){if(!alive())return;try{
        const x=metro.findByProps?.(...props);if(obj(x)){
          const m=methods(x);foundQueries.add(props.join('+')+' -> '+(m.filter(k=>relevant.test(k)).join(', ')||'module returned; methods not enumerable'));
        }
      }catch(_){}await wait();}
      const detailed=[];
      // Known JS getters only. Never call setters, capture, recording or callback-registration methods.
      for(const [label,props] of [['Media engine store',['getMediaEngine','getInputVolume']],['Voice engine wrapper',['getVoiceEngine']],['Media settings actions',['setInputVolume','setNoiseSuppression','setEchoCancellation']],['Mixer settings store',['getAudioMixerSettings']]]){
        if(!alive())return;
        try{const x=metro.findByProps?.(...props);if(!obj(x)){detailed.push(label+' -> not found');continue;}
          detailed.push(describe(label,x));
          for(const k of ['getMediaEngine','getVoiceEngine','getAudioMixerSettings']){
            try{const f=x[k];if(typeof f!=='function')continue;const y=f.call(x);
              if(y&&typeof y.then==='function'){Promise.resolve(y).catch(()=>{});detailed.push(label+'.'+k+'() -> asynchronous result (not inspected)');continue;}
              detailed.push(describe(label+'.'+k+'()',y));
            }catch(_){detailed.push(label+'.'+k+'() -> unavailable or threw');}
          }
        }catch(_){detailed.push(label+' -> lookup failed');}await wait();
      }
      for(const k of ['DCDVoiceEngine','VoiceEngine']){if(!alive())return;try{const x=RN.NativeModules?.[k];if(obj(x))detailed.push(describe('Native '+k,x));}catch(_){}}
      const deeperQueries=['setPitchShift','setFormant','setVoiceFilters','setAudioEffects','setAudioMixerSettings','getAudioMixerSettings','setAudioSamplesCallback','setLocalAudioCallback','setAudioSink','setAudioSource','setAudioProcessor','setAudioProcessingCallback','setAudioTransform','setAudioInputInitializationCallback','setOnVoiceCallback','setSidechainCompression','applyMediaFilterSettingsWithCallback'];
      for(const k of deeperQueries){if(!alive())return;try{const x=metro.findByProps?.(k);if(obj(x))detailed.push(describe('Lookup '+k,x));}catch(_){}await wait();}
      if(alive())report=['MicFX Probe 2','Read-only capability discovery; calls named JS getters, does not record or modify microphone audio. Function arity is indicative only.',...info,'\nNative modules:\n'+([...native].join('\n')||'none found'),'\nTargeted Metro lookups:\n'+([...foundQueries].join('\n')||'none found'),'\nInitialized Metro modules (function names only):\n'+([...modules].join('\n')||'none found'),'\nDetailed engine and getter inspection:\n'+(detailed.join('\n\n')||'none found')].join('\n');
    }catch(_){if(alive())report='MicFX Probe 2\nScan failed before completion. No audio was recorded or modified.';}
    finally{if(id===generation)busy=false;}
  }
  function Settings(){const [text,setText]=React.useState(report),[running,setRunning]=React.useState(busy),[notice,setNotice]=React.useState('');
    const h=React.createElement;
    const txt=(s,style={})=>h(RN.Text,{style:{color:'#e5e7eb',fontSize:15,...style}},s);
    const button=(name,callback,disabled=false)=>h(RN.TouchableOpacity,{accessibilityRole:'button',disabled,onPress:callback,style:{backgroundColor:'#404249',padding:14,borderRadius:10,marginTop:10,opacity:disabled?.5:1}},txt(name,{fontWeight:'600',textAlign:'center'}));
    return h(RN.ScrollView,{style:{flex:1},contentContainerStyle:{padding:16,paddingBottom:48}},
      txt('MicFX Probe 2',{fontSize:22,fontWeight:'bold'}),txt('Join a voice call before scanning. This scan lists audio-related methods and inspects the objects returned by known engine getters. It does not record audio or change voice settings.',{marginTop:8,color:'#b5bac1'}),
      button(running?'Scanning…':'Scan audio capabilities',async()=>{setRunning(true);setNotice('');await scan();setText(report);setRunning(false);},running),
      button('Copy report',()=>{try{const c=RN.Clipboard??metro.common.clipboard??metro.findByProps('setString','getString');if(typeof c?.setString!=='function')throw 0;c.setString(report);setNotice('Copied.');}catch(_){setNotice('Clipboard unavailable. Select the report text to copy.');}},!text||running),
      button('Clear report',()=>{report='';setText('');setNotice('');},running),
      notice?txt(notice,{marginTop:8}):null,
      h(RN.Text,{selectable:true,style:{color:'#dbdee1',backgroundColor:'#202124',borderRadius:8,padding:12,marginTop:18,fontSize:12,fontFamily:'Menlo'}},text||'No scan yet. Join a call, then scan.'));
  }
  // Only numeric preferences and booleans are persisted; no audio or account data.
  const defaults={musicEnabled:false,musicVolume:50,micVolume:100,gain:0,advancedGainEnabled:false,advancedGainDb:0,bypass:false,stereo:false,pitchEnabled:false,pitch:0,detune:0,blend:100,width:0,autoEnable:true,chatButton:false,startupNotice:true,eqEnabled:true,eq0:0,eq1:0,eq2:0,eq3:0,eq4:0,eq5:0,eq6:0,eq7:0};
  const cfg={...defaults}, storage=vendetta.plugin?.storage, limits={musicVolume:[0,100],micVolume:[0,100],gain:[-12,12],advancedGainDb:[0,240],pitch:[-12,12],detune:[-100,100],blend:[0,100],width:[0,100],...Object.fromEntries(Array.from({length:8},(_,i)=>["eq"+i,[-12,12]]))};
  const eqLabels=["85 Hz · Bass shelf","150 Hz · Warmth","300 Hz · Body","600 Hz · Low mids","1.2 kHz · Mids","2.4 kHz · Presence","4.8 kHz · Clarity","8 kHz · Air shelf"];
  const eqPresets={Flat:[0,0,0,0,0,0,0,0],Deep:[5,4,1,-2,-1,0,0,0],Warm:[2,3,2,0,-1,0,0,-1],Clear:[-2,-2,-1,0,1,3,2,1]};
  const listeners=new Set(); let storageOK=!!storage;
  function notify(){for(const f of [...listeners]){try{f();}catch(_){}}}
  function save(){try{if(!storage)throw 0;storage.micfxConfig={...cfg};storageOK=true;}catch(_){storageOK=false;}notify();}
  function load(){try{const prior=storage?.micfxConfig;for(const k of Object.keys(defaults)){const v=prior?.[k];if(typeof defaults[k]==='boolean'){if(typeof v==='boolean')cfg[k]=v;}else if(typeof v==='number'&&Number.isFinite(v))cfg[k]=clamp(v,...limits[k]);}}catch(_){storageOK=false;}}
  const presetKeys=['musicEnabled','musicVolume','micVolume','pitchEnabled','gain','advancedGainEnabled','advancedGainDb','pitch','detune','blend','eqEnabled','stereo','bypass','width',...Array.from({length:8},(_,i)=>'eq'+i)];
  function presetSnapshot(){return Object.fromEntries(presetKeys.map(k=>[k,cfg[k]]));}
  function savedPresets(){
    try{const data=storage?.micfxPresets;if(!Array.isArray(data))return [];
      return data.filter(x=>x&&typeof x.name==='string'&&x.name.length>0&&x.name.length<=36&&x.values&&typeof x.values==='object').slice(0,16);
    }catch(_){return [];}
  }
  function saveNamedPreset(name){
    const trimmed=String(name||'').trim().slice(0,36);
    if(!trimmed)return 'Enter a preset name first.';
    try{
      if(!storage)throw Error('Storage unavailable');
      const items=savedPresets(),i=items.findIndex(x=>x.name.toLowerCase()===trimmed.toLowerCase());
      const item={name:trimmed,values:presetSnapshot()};
      if(i!==-1)items[i]=item;
      else if(items.length>=16)return 'Limit reached: delete a preset before saving another.';
      else items.push(item);
      storage.micfxPresets=items;notify();
      return i!==-1?'Updated preset: '+trimmed:'Saved preset: '+trimmed;
    }catch(_){return 'Could not save preset. Check plugin storage.';}
  }
  function loadNamedPreset(name){
    const item=savedPresets().find(x=>x.name===name);
    if(!item)return 'Preset not found.';
    for(const k of presetKeys){
      const v=item.values[k];
      if(typeof defaults[k]==='boolean'){if(typeof v==='boolean')cfg[k]=v;}
      else if(typeof v==='number'&&Number.isFinite(v)&&limits[k])cfg[k]=clamp(v,...limits[k]);
    }
    save();void applyControls();
    return 'Loaded preset: '+name;
  }
  function deleteNamedPreset(name){
    try{if(!storage)throw Error('Storage unavailable');
      const items=savedPresets(),remaining=items.filter(x=>x.name!==name);
      if(remaining.length===items.length)return 'Preset not found.';
      storage.micfxPresets=remaining;notify();return 'Deleted preset: '+name;
    }catch(_){return 'Could not delete preset.';}
  }
  function useRefresh(){const [,set]=React.useState(0);React.useEffect(()=>{const f=()=>set(x=>x+1);listeners.add(f);return ()=>listeners.delete(f);},[]);return ()=>set(x=>x+1);}

  const pairs=[['getNoiseCancellation','setNoiseCancellation'],['getNoiseSuppression','setNoiseSuppression'],['getAutomaticGainControl','setAutomaticGainControl'],['getEchoCancellation','setEchoCancellation'],['getBypassSystemInputProcessing','setBypassSystemInputProcessing']];
  let stereoActive=false;
  let baseline=null, filtered=null, status='No audio changes applied.', stereoSeen=0, stereoChanged=0, stereoHooks=0, gainTarget=null, restoring=null;
  const offs=[], hooked=new WeakMap();
  const clamp=(n,min,max)=>Math.max(min,Math.min(max,n));
  function lookup(...p){try{return metro.findByProps?.(...p);}catch(_){return null;}}
  function endpoints(){const store=lookup('getInputVolume','getMediaEngine');const actions=lookup('setInputVolume','setNoiseSuppression','setEchoCancellation');return {store,actions};}
  function getSetting(store,key){try{return store?.[key]?.call(store);}catch(_){return undefined;}}
  function available(x,k){try{return typeof x?.[k]==='function';}catch(_){return false;}}
  async function setSetting(actions,key,val){if(!available(actions,key))throw Error('unavailable');await actions[key].call(actions,val);}
  async function restoreGain(){if(!baseline)return;const b=baseline;await setSetting(b.actions,'setInputVolume',b.value);baseline=null;gainTarget=null;}
  async function restoreFilters(){if(!filtered)return;const f=filtered;let failed=0;for(const [key,value] of [...f.saved].reverse()){try{await setSetting(f.actions,key,value);f.saved.delete(key);}catch(_){failed++;}}if(!f.saved.size){filtered=null;try{if(storage)storage.micfxOriginalFilters={};}catch(_){}}else{try{if(storage)storage.micfxOriginalFilters=Object.fromEntries(f.saved);}catch(_){}}if(failed)throw Error('Some original filters could not be restored');}
  function plain(o){if(!o||typeof o!=='object'||Array.isArray(o))return false;try{const p=Object.getPrototypeOf(o);return p===Object.prototype||p===null;}catch(_){return false;}}
  function stereoArgs(args){if(!live||!stereoActive||!Array.isArray(args))return args;try{
    return args.map(o=>{if(!plain(o)||!plain(o.audioEncoder))return o;const e=o.audioEncoder,p=plain(e.params)?e.params:null;
      stereoSeen++;const top=typeof e.channels==='number'&&(e.channels===1||e.channels===2),nested=p&&typeof p.channels==='number'&&(p.channels===1||p.channels===2);
      // Only change fields actually present, no invented parameters, no encryption or bitrate changes.
      if(!top&&!nested)return o;const copy={...e};if(top)copy.channels=2;if(nested)copy.params={...p,channels:2};stereoChanged++;return {...o,audioEncoder:copy};});
  }catch(_){return args;}}
  function installStereoHooks(){const before=vendetta.patcher?.before;if(typeof before!=='function')return;
    const {store}=endpoints(), wrap=lookup('getVoiceEngine'), direct=lookup('setTransportOptions','createVoiceConnectionWithOptions');
    const targets=[direct,wrap,getSetting(wrap,'getVoiceEngine'),getSetting(store,'getMediaEngine')];
    for(const k of ['DCDVoiceEngine','VoiceEngine']){try{targets.push(RN.NativeModules?.[k]);}catch(_){}try{targets.push(RN.TurboModuleRegistry?.get?.(k));}catch(_){}}
    for(const t of targets){if(!obj(t))continue;let set=hooked.get(t);if(!set){set=new Set();hooked.set(t,set);}for(const k of ['setTransportOptions','connectionInstanceSetTransportOptions']){if(set.has(k)||!available(t,k))continue;try{const off=before(k,t,stereoArgs);if(typeof off==='function'){offs.push(off);set.add(k);stereoHooks++;}}catch(_){}}}
  }
  const readNative=k=>{try{return RN.Settings?.get?.(k);}catch(_){return undefined;}};
  const nativeStatus=()=>readNative('MicFXPitchStatus')||'Native library not detected (or status not yet available).';
  let nativeWatch=null;let request=0, writing=false, startupTimer=null, startupRun=0, applyAgain=false, startupState='Not checked', chatHooks=0, chatSeen=0;
  function nativeDisable(){try{RN.Settings?.set?.({MicFXPitchEnabled:0,MicFXMusicEnabled:0});}catch(_){}}
  function applyNative(){if(typeof RN.Settings?.set!=='function')throw Error('iOS Settings bridge unavailable');request=Math.max(Date.now(),request+1);RN.Settings.set({MicFXPitchEnabled:cfg.pitchEnabled?1:0,MicFXPitchSemitones:cfg.pitch,MicFXPitchDetune:cfg.detune,MicFXPitchBlend:cfg.blend,MicFXPitchGain:cfg.gain,MicFXAdvancedGainEnabled:cfg.advancedGainEnabled?1:0,MicFXAdvancedGainDb:cfg.advancedGainDb,MicFXEQEnabled:cfg.eqEnabled?1:0,...Object.fromEntries(eqLabels.map((_,i)=>["MicFXEQ"+i,cfg["eq"+i]])),MicFXMusicEnabled:cfg.musicEnabled?1:0,MicFXMusicVolume:cfg.musicVolume,MicFXMicVolume:cfg.micVolume,MicFXRequestID:request});return cfg.pitchEnabled?'Native pitch, EQ and gain settings sent.':'Native processor disabled.';}
  function bridgeState(){if(!request)return 'Checking native library…';if(Number(readNative('MicFXNativeAck'))!==request)return 'Waiting for native response…';if(Number(readNative('MicFXNativeVersion'))!==4)return 'Native library version mismatch; rebuild v4.';if(Number(readNative('MicFXNativeHooked'))!==1)return 'Native hook unavailable: '+nativeStatus();if(!cfg.pitchEnabled)return 'MicFX disabled';if(Number(readNative('MicFXNativeOn'))!==1)return 'Native processor not enabled';return /buffers processed/.test(nativeStatus())?'MicFX enabled · processing audio':'MicFX enabled · waiting for microphone';}
  function toast(t){try{vendetta.ui?.toasts?.showToast?.(t);}catch(_){}}
  function checkStartup(){const id=++startupRun;let attempts=0;clearTimeout(startupTimer);startupState='Checking native processor…';notify();const tick=()=>{if(!live||id!==startupRun)return;const t=bridgeState();if(t.startsWith('MicFX enabled')||t==='MicFX disabled'||t.startsWith('Native hook unavailable')||t.startsWith('Native library version mismatch')||++attempts>=24){startupState=t==='Waiting for native response…'?'MicFX: no native acknowledgment. Check v4 dylib.':t;notify();if(cfg.startupNotice)toast(startupState);return;}startupTimer=setTimeout(tick,250);};startupTimer=setTimeout(tick,250);}
  function nativeChange(){if(!live)return;try{applyNative();}catch(_){status='Native settings write failed.';}notify();}
  function setConfig(k,v){cfg[k]=v;save();if(k==='chatButton'||k==='startupNotice'||k==='autoEnable'||k==='width')return;if(k==='bypass'||k==='stereo'){void applyControls();return;}nativeChange();}
  function setPreset(values){for(let i=0;i<8;i++)cfg['eq'+i]=values[i];cfg.eqEnabled=true;save();nativeChange();}
  async function applyControls(){if(!live)return;if(writing){applyAgain=true;return;}writing=true;const messages=[];try{
    // Send native changes immediately; gain is real DSP, never a Discord volume slider.
    try{messages.push(applyNative());}catch(_){messages.push('Native settings write failed.');}
    const {store,actions}=endpoints();
    messages.push(cfg.pitchEnabled?'Gain: native DSP with peak limiter.':'Gain and pitch are inactive while the native processor is off.');
    if(cfg.bypass){try{if(!filtered){const saved=new Map();let prior;try{prior=storage?.micfxOriginalFilters;}catch(_){}for(const [g,s] of pairs){const v=typeof prior?.[s]==='boolean'?prior[s]:getSetting(store,g);if(typeof v==='boolean'&&available(actions,s))saved.set(s,v);}filtered={actions,saved};try{if(storage)storage.micfxOriginalFilters=Object.fromEntries(saved);}catch(_){}}let count=0;for(const [,s] of pairs){try{if(!filtered.saved.has(s))continue;await setSetting(filtered.actions,s,s==='setBypassSystemInputProcessing');count++;}catch(_){}}messages.push('Filters: '+count+'/5 filter/system bypass requests accepted. Verify in Discord settings; native processing may remain.');}catch(_){messages.push('Filter bypass unavailable.');}}
    else {try{if(!filtered){const saved=new Map();try{const prior=storage?.micfxOriginalFilters;for(const [,k] of pairs)if(typeof prior?.[k]==='boolean')saved.set(k,prior[k]);}catch(_){}if(saved.size)filtered={actions,saved};}await restoreFilters();messages.push('Filters: original settings retained/restored.');}catch(_){messages.push('Filter restoration incomplete; restore in Discord settings.');}}
    stereoActive=live&&cfg.stereo; if(stereoActive){installStereoHooks();messages.push('Stereo: '+stereoHooks+' transport hooks installed; '+stereoChanged+' encoder requests changed. Rejoin call to test; true stereo not confirmed.');}else messages.push('Stereo request off; rejoin call to restore negotiated format.');
    if(!live)nativeDisable();messages.push('8-band native EQ: '+(cfg.eqEnabled?'enabled':'off')+'. Stereo widening remains a preview.');status=messages.join('\n');
  }finally{writing=false;notify();if(applyAgain&&live){applyAgain=false;void applyControls();}}}
  const typeNames=t=>typeof t==='string'?[t]:[t?.displayName,t?.name,t?.render?.displayName,t?.render?.name,t?.type?.displayName,t?.type?.name].filter(Boolean);
  function FXButton(){useRefresh();if(!live||!cfg.chatButton)return null;const h=React.createElement;return h(RN.TouchableOpacity,{accessibilityRole:'button',accessibilityLabel:cfg.pitchEnabled?'Disable MicFX':'Enable MicFX',onPress:()=>setConfig('pitchEnabled',!cfg.pitchEnabled),style:{paddingHorizontal:7,paddingVertical:6,borderRadius:10,backgroundColor:cfg.pitchEnabled?'#5865f2':'#404249',marginHorizontal:2}},h(RN.Text,{style:{color:'#fff',fontWeight:'bold',fontSize:12}},'FX'));}
  function ChatActions({original}){useRefresh();const h=React.createElement;return !live||!cfg.chatButton?original:h(RN.View,{style:{flexDirection:'row',alignItems:'center'}},h(FXButton),original);}
  function installChat(){chatHooks=chatSeen=0;const after=vendetta.patcher?.after;if(typeof after!=='function')return;const attach=(o,k)=>{if(typeof o?.[k]!=='function')return;try{const off=after(k,o,(args,out)=>{if(!live||!out||!typeNames(args[0]).includes('ChatInputRightActions'))return;chatSeen++;return React.createElement(ChatActions,{original:out,key:out.key??undefined});});if(typeof off==='function'){offs.push(off);chatHooks++;}}catch(_){}};attach(React,'createElement');const rt=lookup('jsx','jsxs');for(const k of ['jsx','jsxs','jsxDEV'])attach(rt,k);}

  function TouchRail({value,min,max,disabled,onChange,preview}){const h=React.createElement,w=React.useRef(0),[drag,setDrag]=React.useState(null),current=React.useRef(null);const pick=e=>{const x=e?.nativeEvent?.locationX;if(!Number.isFinite(x)||!w.current)return null;return clamp(Math.round(min+clamp(x/w.current,0,1)*(max-min)),min,max);};const move=e=>{const n=pick(e);if(n!==null){current.current=n;setDrag(n);}};const end=e=>{const n=pick(e)??current.current;setDrag(null);current.current=null;if(n!==null&&n!==value&&!disabled)onChange(n);};const f=clamp(((drag??value)-min)/(max-min),0,1);return h(RN.View,{accessible:true,accessibilityRole:'adjustable',accessibilityValue:{min,max,now:value},accessibilityActions:[{name:'increment'},{name:'decrement'}],onAccessibilityAction:e=>{if(!disabled)onChange(clamp(value+(e.nativeEvent.actionName==='increment'?1:-1),min,max));},onLayout:e=>{w.current=e.nativeEvent.layout.width;},onStartShouldSetResponder:()=>!disabled,onMoveShouldSetResponder:()=>!disabled,onResponderGrant:move,onResponderMove:move,onResponderRelease:end,onResponderTerminate:()=>{current.current=null;setDrag(null);},style:{height:34,justifyContent:'center',opacity:disabled?.45:1}},h(RN.View,{pointerEvents:'none',style:{height:5,backgroundColor:'#454850',borderRadius:5}},h(RN.View,{style:{position:'absolute',left:0,width:(100*f)+'%',height:5,backgroundColor:preview?'#777b89':'#818cf8',borderRadius:5}}),h(RN.View,{style:{position:'absolute',left:(100*f)+'%',marginLeft:-7,top:-5,width:15,height:15,borderRadius:8,backgroundColor:'#d5d8ff'}})),drag!==null?h(RN.Text,{pointerEvents:'none',style:{position:'absolute',right:0,top:-9,color:'#a3aaff',fontSize:11}},String(drag)):null);}
  function Controls(){const h=React.createElement;const update=useRefresh(),[busyUI,setBusyUI]=React.useState(false),[showProbe,setShowProbe]=React.useState(false),[presetName,setPresetName]=React.useState(''),[presetNotice,setPresetNotice]=React.useState(''),[advancedInput,setAdvancedInput]=React.useState(String(cfg.advancedGainDb)),[advancedNotice,setAdvancedNotice]=React.useState('');React.useEffect(()=>{const t=setInterval(update,500);return ()=>clearInterval(t);},[]);
    const txt=(t,s={})=>h(RN.Text,{style:{color:'#e5e7eb',fontSize:15,...s}},t);
    const sub=t=>txt(t,{color:'#aeb4bf',fontSize:12,lineHeight:18,marginTop:5});
    const button=(t,fn,disabled=false)=>h(RN.TouchableOpacity,{accessibilityRole:'button',disabled,onPress:fn,style:{padding:12,borderRadius:9,backgroundColor:'#404249',opacity:disabled?.4:1,alignItems:'center'}},txt(t,{fontWeight:'600'}));
    const card=(title,children)=>h(RN.View,{style:{padding:14,backgroundColor:'#24262d',borderRadius:14,marginTop:12}},txt(title,{fontSize:17,fontWeight:'700',marginBottom:8}),...children);
    const step=(label,key,min,max,unit,signed,preview=false)=>{const value=cfg[key],fmt=(n)=>`${signed&&n>0?'+':''}${n}${unit}`,change=n=>setConfig(key,clamp(n,min,max));return h(RN.View,{style:{marginBottom:14}},h(RN.View,{style:{flexDirection:'row',justifyContent:'space-between',alignItems:'center'}},txt(label),txt(fmt(value),{fontWeight:'bold',color:preview?'#b9bbc4':'#a3aaff'})),h(TouchRail,{value,min,max,disabled:busyUI||preview,onChange:change,preview}),h(RN.View,{style:{flexDirection:'row',justifyContent:'space-between',alignItems:'center'}},button('−',()=>change(value-1),busyUI||preview||value<=min),button('Reset',()=>change(key==='blend'||key==='micVolume'?100:key==='musicVolume'?50:0),busyUI||preview),button('+',()=>change(value+1),busyUI||preview||value>=max)),sub(fmt(min)+' to '+fmt(max)+(preview?' · Not implemented':'')));};
    const eqPlot=()=>h(RN.View,{style:{height:112,marginBottom:12,borderRadius:10,paddingHorizontal:5,paddingTop:8,backgroundColor:'#181a20'}},h(RN.View,{style:{position:'absolute',top:50,left:6,right:6,height:1,backgroundColor:'#50515b'}},null),h(RN.View,{style:{flexDirection:'row',height:94}},...eqLabels.map((label,i)=>{const v=cfg['eq'+i],bar=Math.abs(v)*3.25;return h(RN.View,{key:label,style:{flex:1,alignItems:'center'}},h(RN.View,{style:{height:78,width:'100%',alignItems:'center'}},h(RN.View,{style:{position:'absolute',top:v>=0?42-bar:42,width:'54%',height:Math.max(2,bar),backgroundColor:cfg.eqEnabled?'#818cf8':'#656875',borderRadius:3}})),txt(['85','150','300','600','1.2k','2.4k','4.8k','8k'][i],{fontSize:9,color:'#afb4c4'}));}))); 
    const eqRow=(label,i)=>{const key='eq'+i,v=cfg[key];return h(RN.View,{key,style:{marginBottom:9}},h(RN.View,{style:{flexDirection:'row',justifyContent:'space-between',alignItems:'center'}},txt(label,{fontSize:13}),txt((v>0?'+':'')+v+' dB',{fontWeight:'700',color:'#a3aaff',fontSize:13})),h(RN.View,{style:{flexDirection:'row',alignItems:'center'}},button('−',()=>setConfig(key,clamp(v-1,-12,12)),busyUI||!cfg.eqEnabled||v<=-12),h(RN.View,{style:{flex:1,marginHorizontal:10}},h(TouchRail,{value:v,min:-12,max:12,disabled:busyUI||!cfg.eqEnabled,onChange:n=>setConfig(key,n)})),button('+',()=>setConfig(key,clamp(v+1,-12,12)),busyUI||!cfg.eqEnabled||v>=12)));};
    const toggle=(label,key,desc)=>h(RN.View,{style:{marginBottom:12}},h(RN.View,{style:{flexDirection:'row',justifyContent:'space-between',alignItems:'center'}},txt(label,{fontWeight:'600'}),h(RN.Switch,{value:cfg[key],disabled:busyUI,onValueChange:v=>{setConfig(key,v);}})),sub(desc));
    const run=async(reset=false)=>{if(busyUI||writing)return;setBusyUI(true);if(reset){Object.assign(cfg,{...defaults,autoEnable:false});save();}try{await applyControls();}finally{setBusyUI(false);update();}};
    return h(RN.ScrollView,{style:{flex:1},contentContainerStyle:{padding:16,paddingBottom:50}},txt('MicFX',{fontSize:26,fontWeight:'bold'}),sub('v4 · Music bridge test · settings saved automatically'),card('Startup & status',[txt(bridgeState(),{fontWeight:'700',color:bridgeState().startsWith('MicFX enabled')?'#64d99a':'#e5e7eb'}),sub(startupState),toggle('Enable MicFX processing','pitchEnabled','Master switch for native pitch, gain and EQ.'),toggle('Automatically enable on launch','autoEnable','Restores your saved audio configuration and enables the processor each launch.'),toggle('Show startup notification','startupNotice','Reports the native library acknowledgment; an idle microphone is not a live audio test.'),toggle('Chat-bar FX button','chatButton','Adds a quick native processor toggle next to the chat actions.'),sub('Chat hooks: '+chatHooks+' · composer renders: '+chatSeen+(storageOK?' · Storage ready':' · Storage unavailable'))]),
    card('Saved presets',[
      sub('Save your current pitch, EQ, gain, music bridge, and audio filter settings. Loading a preset applies it immediately. Maximum 16 presets.'),
      h(RN.TextInput,{
        value:presetName,
        onChangeText:setPresetName,
        placeholder:'Preset name',
        placeholderTextColor:'#9ca3af',
        maxLength:36,
        autoCorrect:false,
        style:{backgroundColor:'#181a20',color:'#fff',borderRadius:9,paddingHorizontal:12,paddingVertical:11,marginTop:10,marginBottom:8}
      }),
      button('Save / overwrite current settings',()=>{
        const result=saveNamedPreset(presetName);setPresetNotice(result);
      },busyUI),
      presetNotice?sub(presetNotice):null,
      ...savedPresets().map(item=>h(RN.View,{
        key:item.name,
        style:{marginTop:10,padding:10,borderRadius:9,backgroundColor:'#181a20',gap:8}
      },
        txt(item.name,{fontWeight:'600'}),
        h(RN.View,{style:{flexDirection:'row',gap:8}},
          h(RN.View,{style:{flex:1}},button('Load',()=>{setPresetNotice(loadNamedPreset(item.name));setAdvancedInput(String(cfg.advancedGainDb));},busyUI)),
          h(RN.View,{style:{flex:1}},button('Delete',()=>setPresetNotice(deleteNamedPreset(item.name)),busyUI))
        )
      )),
      !savedPresets().length?sub('No saved presets yet.'):null
    ]),
    card('Music bridge test',[toggle('Enable music bridge','musicEnabled','Mix Spotify Bridge audio into outgoing microphone. Your setting is remembered across launches.'),step('Music volume','musicVolume',0,100,'%',false),step('Microphone mix volume','micVolume',0,100,'%',false),sub(String(readNative('MicFXMusicStatus')||'Waiting for native library')),sub('Packets: '+(readNative('MicFXMusicPackets')||0)+' · Mixed buffers: '+(readNative('MicFXMusicMixed')||0)),
      sub('Audio mixing hooks: '+(readNative('MicFXMixSessionHooks')||0)+' · Session updates: '+(readNative('MicFXMixSessionPatches')||0)+' · Apply failures: '+(readNative('MicFXMixSessionFailures')||0))]),card('Input gain',[step('Microphone gain','gain',-12,12,' dB',true),sub('Standard DSP gain: -12 to +12 dB. Advanced Gain overrides this slider when enabled. The microphone processor must be enabled.')]),
    card('Advanced Gain',[
      toggle('Enable advanced gain override','advancedGainEnabled','Applies the custom input boost instead of the regular gain slider. Saved across launches and included in presets.'),
      sub('Custom gain in dB. Values above +65 dB are accepted. For numerical safety, the input range is 0 to +240 dB.'),
      h(RN.TextInput,{
        value:advancedInput,
        onChangeText:setAdvancedInput,
        keyboardType:'decimal-pad',
        placeholder:'Enter gain in dB (e.g. 72)',
        placeholderTextColor:'#9ca3af',
        maxLength:10,
        style:{backgroundColor:'#181a20',color:'#fff',borderRadius:9,paddingHorizontal:12,paddingVertical:12,marginTop:10,marginBottom:8}
      }),
      button('Apply custom gain',()=>{
        const input=advancedInput.trim();
        const value=Number(input);
        if(!input||!Number.isFinite(value)||value<0||value>240){setAdvancedNotice('Enter a number from 0 to 240 dB.');return;}
        setConfig('advancedGainDb',Math.round(value*10)/10);
        setAdvancedNotice('Advanced gain set to +'+(Math.round(value*10)/10)+' dB. Enable Advanced Gain and MicFX processing to use it.');
      },busyUI),
      sub('Requested gain: '+((cfg.advancedGainEnabled?cfg.advancedGainDb:cfg.gain)>0?'+':'')+(cfg.advancedGainEnabled?cfg.advancedGainDb:cfg.gain)+' dB'+(cfg.advancedGainEnabled?' (custom override)':' (standard)')),sub('Native DSP applied: '+(readNative('MicFXAppliedGainDb')??'not reported')+' dB (0 means processor disabled)'),
      sub('High gain amplifies background noise and can cause strong distortion. The native peak limiter keeps the resulting PCM within digital full scale; it does not increase microphone hardware output.'),
      advancedNotice?sub(advancedNotice):null
    ]),card('Pitchproof-style processor',[step('Pitch','pitch',-12,12,' st',true),step('Detune','detune',-100,100,' cents',true),step('Blend','blend',0,100,'%',false),sub(nativeStatus()),sub('Capture rate: '+(Number(readNative('MicFXNativeRate'))||'unknown')+' Hz')]),card('8-band microphone EQ',[toggle('Enable equalizer','eqEnabled','Native microphone equalizer, applied after pitch and before gain.'),eqPlot(),h(RN.View,{style:{flexDirection:'row',flexWrap:'wrap',gap:7,marginBottom:12}},...Object.entries(eqPresets).map(([name,values])=>h(RN.View,{key:name},button(name,()=>setPreset(values),busyUI)))),...eqLabels.map(eqRow),sub('85 Hz and 8 kHz are shelves; other bands are bell filters. High bands outside the current capture bandwidth are skipped. Bass boosts may trigger the limiter.'),button('Reset EQ to flat',()=>setPreset(eqPresets.Flat),busyUI)]),card('Stereo & width',[toggle('Request stereo encoding','stereo','Experimental: changes existing encoder channel fields only. Rejoin call and verify with another listener.'),step('Stereo widening','width',0,100,'%',false,true),sub('True widening requires PCM processing; mono capture may remain mono.')]),card('Original Discord processing',[toggle('Disable Discord filters','bypass','Requests noise suppression, noise cancellation, AGC and echo cancellation off. Prefer headphones to avoid echo.'),sub('Also requests system input processing bypass if exposed. Use headphones; some filters may remain active.')]),h(RN.View,{style:{marginTop:14}},button(busyUI?'Applying…':'Apply audio controls',()=>run(),busyUI)),h(RN.View,{style:{marginTop:8}},button('Reset / restore original settings',()=>run(true),busyUI)),card('Status',[txt(status,{fontSize:13,lineHeight:19}),sub('Transport hooks: '+stereoHooks+' · Encoder options observed: '+stereoSeen+' · Requests changed: '+stereoChanged),button('Refresh status',update,busyUI)]),h(RN.View,{style:{marginTop:12}},button(showProbe?'Hide diagnostics':'Show diagnostics',()=>setShowProbe(!showProbe))),showProbe?h(RN.View,{style:{height:650,marginTop:12}},h(Settings)):null);
  }
  return {settings:Controls,onLoad(){if(live)return;live=true;load();cfg.pitchEnabled=cfg.autoEnable;save();installChat();try{nativeWatch=RN.Settings?.watchKeys?.(["MicFXNativeAck","MicFXNativeOn","MicFXNativeHooked","MicFXPitchStatus","MicFXNativeRate","MicFXMusicPackets","MicFXMusicMixed","MicFXMusicStatus","MicFXMixSessionHooks","MicFXMixSessionPatches","MicFXMixSessionFailures","MicFXAppliedGainDb"],notify);}catch(_){}void applyControls();checkStartup();},onUnload(){live=false;startupRun++;clearTimeout(startupTimer);try{if(nativeWatch!=null)RN.Settings?.clearWatch?.(nativeWatch);}catch(_){}nativeWatch=null;nativeDisable();stereoActive=false;generation++;busy=false;report='';for(const off of offs.splice(0)){try{off();}catch(_){}};restoring=Promise.resolve().then(async()=>{while(writing)await new Promise(r=>setTimeout(r,20));try{await restoreGain();}catch(_){}try{await restoreFilters();}catch(_){}});}};
})()
