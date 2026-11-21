(() => {
    'use strict';
    const rowPath = 'modules/voice_panel/native/controls/useControlsButtons.tsx';
    const wrapperPath = 'modules/voice_panel/native/controls/buttons/VoicePanelAnimatedButtonWrapper.tsx';
    const codecPath = '../discord_common/js/packages/media-engine/native/Connection.tsx';
    const iconPath = 'design/components/Icon/native/redesign/generated/MicrophoneIcon.tsx';
    const slotKey = 'micfx-voice-settings';
    let rowReady = false, codecReady = false, codecRequests = 0;
    const cache = new WeakMap();

    function addSlot(original, render) {
        if (!Array.isArray(original) || original.some(s => s.key === slotKey)) return original;
        const leave = original.findIndex(s => s.key === 'connected-disconnect');
        if (leave < 0 || !original.every(s => Number.isFinite(s.x) && s.width > 0)) return original;
        const mic = original.findIndex(s => s.key === 'connected-mic' || s.key === 'connected-ptt');
        const model = original[mic >= 0 ? mic : leave];
        const row = original.slice();
        row.splice(mic >= 0 ? mic + 1 : leave, 0, {...model, key:slotKey, type:'icon-normal', render});
        const first = original[0], last = original[original.length - 1];
        const start = first.x - first.width / 2;
        const length = last.x + last.width / 2 - start;
        if (!(length > 0)) return original;
        const sum = row.reduce((n, s) => n + s.width, 0);
        const gap = Math.min(12, Math.max(2, (length - sum) / (row.length - 1)));
        const scale = (length - gap * (row.length - 1)) / sum;
        if (!(scale > 0)) return original;
        let next = start;
        return row.map(s => {
            const width = s.width * scale, x = next + width / 2;
            next += width + gap;
            return {...s, width, x};
        });
    }

    function install() {
        const vd = globalThis.vendetta, metro = globalThis.bunny?.metro;
        if (!vd?.patcher?.after || typeof metro?.findByFilePath !== 'function') return;
        const RN = vd.metro.common.ReactNative, React = vd.metro.common.React;
        const settings = RN?.Settings;
        if (!settings || !React) return;
        const h = React.createElement;
        if (!codecReady) {
            const proto = metro.findByFilePath(codecPath)?.default?.prototype;
            if (typeof proto?.getCodecOptions === 'function') {
                vd.patcher.after('getCodecOptions', proto, (_, opts) => {
                    const enc = opts?.audioEncoder;
                    if (Number(settings.get('MicFXStereoRequested')) !== 1 ||
                        !enc || String(enc.name).toLowerCase() !== 'opus') return;
                    codecRequests++;
                    return {...opts, audioEncoder:{...enc, channels:2}};
                });
                codecReady = true;
            }
        }
        if (rowReady) return;
        const mod = metro.findByFilePath(rowPath);
        const Wrapper = metro.findByFilePath(wrapperPath)?.default;
        const Icon = metro.findByFilePath(iconPath)?.MicrophoneIcon;
        if (typeof mod?.default !== 'function' || !Wrapper || !Icon) return;

        function existingSettings() {
            const manager = vd.plugins;
            for (const [id, entry] of Object.entries(manager?.plugins || {})) {
                if (!entry?.enabled || !/^micfx(?:\b|\s)/i.test(entry.manifest?.name || '')) continue;
                const component = manager.getSettings(id);
                if (component) return component;
            }
            return null;
        }
        function Panel({close}) {
            const [,refresh] = React.useReducer(v => v+1, 0);
            const current = key => Number(settings.get(key)) || 0;
            const [input,setInput] = React.useState(String(settings.get('MicFXCleanGainDb') ?? 35));
            const [error,setError] = React.useState('');
            const [showQuick,setShowQuick] = React.useState(true);
            React.useEffect(() => {
                const id = settings.watchKeys?.('MicFXVoiceChannels', refresh);
                return () => { if (id != null) settings.clearWatch?.(id); };
            }, []);
            function write(values) { settings.set(values); refresh(); }
            function boost(db) {
                write({MicFXCleanGainDb:db,MicFXCleanBoostOn:1,MicFXRmsEnabled:0});
                setInput(String(db));setError('');
            }
            const text = (label, style) => h(RN.Text,{style:{color:'#f1f2f5',...style}},label);
            const pill = (label,on,press) => h(RN.Pressable,{key:label,accessibilityRole:'button',
                accessibilityState:{selected:!!on},onPress:press,
                style:{backgroundColor:on?'#5148a3':'#2b2c32',paddingHorizontal:10,paddingVertical:8,borderRadius:9}},
                text(label,{fontSize:14,fontWeight:'600'}));
            const line = (children) => h(RN.View,{style:{flexDirection:'row',flexWrap:'wrap',alignItems:'center',gap:6,marginVertical:3}},...children);
            const pan = (name,key) => line([text(name,{width:54}),...['Left','Center','Right'].map((label,i) =>
                pill(label,current(key)===i-1,()=>write(i===1?{[key]:0}:{[key]:i-1,MicFXStereoRequested:1})))]);
            const stereo = current('MicFXStereoRequested'), count = current('MicFXVoiceChannels');
            const Plugin = existingSettings();
            return h(RN.SafeAreaView || RN.View,{style:{flex:1,backgroundColor:'#151519'}},
                h(RN.View,{style:{flexDirection:'row',alignItems:'center',justifyContent:'space-between',paddingHorizontal:14,paddingVertical:7}},
                    text('MicFX',{fontWeight:'700',fontSize:22}),
                    line([pill('Call controls',showQuick,()=>setShowQuick(!showQuick)),pill('Done',false,close)])),
                showQuick && h(RN.ScrollView,{style:{flexGrow:0,maxHeight:Plugin?'55%':'90%'},contentContainerStyle:{paddingHorizontal:14,paddingBottom:10}},
                    line([text('Mic gain'),pill('Original',!current('MicFXCleanBoostOn')&&!current('MicFXRmsEnabled'),()=>write({MicFXCleanBoostOn:0,MicFXRmsEnabled:0})),
                        pill('RMS',current('MicFXRmsEnabled'),()=>write({MicFXCleanBoostOn:0,MicFXRmsEnabled:1,MicFXRmsTargetDb:-3})),
                        pill('+35 dB',current('MicFXCleanBoostOn')&&current('MicFXCleanGainDb')===35,()=>boost(35))]),
                    line([h(RN.TextInput,{key:'input',accessibilityLabel:'Custom microphone gain in decibels',value:input,onChangeText:setInput,
                        placeholder:'Gain in dB',placeholderTextColor:'#aaa',keyboardType:'numbers-and-punctuation',
                        style:{color:'#fff',minWidth:90,padding:7,backgroundColor:'#25252a',borderRadius:6}}),
                        pill('Apply dB',current('MicFXCleanBoostOn'),()=>{const db=Number(input);
                            if(!input.trim()||!Number.isFinite(db)){setError('Enter a finite dB value.');return;}boost(db);})]),
                    !!error && text(error,{color:'#ffaeae'}),
                    line([pill('Outgoing stereo',stereo,()=>write({MicFXStereoRequested:stereo?0:1})),
                        text(count ? 'Capture: '+(count===2?'stereo':'mono') : 'Waiting for capture',{fontSize:13})]),
                    pan('Mic','MicFXVoiceSide'),pan('Music','MicFXMusicSide'),
                    text(stereo ? 'Rejoin after changing stereo. Opus stereo requests this session: '+codecRequests : 'Mono routes play both sources in the center.',{fontSize:12,color:'#bdbdc8',marginTop:4})),
                Plugin && h(RN.View,{style:{flex:1,minHeight:0}},h(Plugin)));
        }
        function Shortcut({buttonProps}) {
            const [open,setOpen] = React.useState(false);
            return h(React.Fragment,null,
                h(Wrapper,{props:buttonProps.props,onPress:()=>setOpen(true),accessibilityLabel:'Open MicFX settings',
                    style:{alignItems:'center',justifyContent:'center',backgroundColor:'#353047',borderRadius:14}},
                    h(Icon,{size:22,color:'#ded8ff'}),
                    h(RN.Text,{allowFontScaling:false,style:{fontSize:8,lineHeight:9,color:'#ded8ff',fontWeight:'800'}},'FX')),
                open && h(RN.Modal,{visible:true,animationType:'slide',presentationStyle:'fullScreen',
                    onRequestClose:()=>setOpen(false)},h(Panel,{close:()=>setOpen(false)})));
        }
        function render(key, props) { return h(Shortcut,{key,buttonProps:props}); }
        vd.patcher.after('default',mod,(_,original) => {
            if(!Array.isArray(original))return;
            if(!cache.has(original)) cache.set(original,addSlot(original,render));
            return cache.get(original);
        });
        rowReady = true;
    }

    // The client loads the call UI and voice engine independently.
    function start() {
        try { install(); } catch (_) {}
        if (!rowReady || !codecReady) setTimeout(start,2000);
    }
    setTimeout(start,0);
})();
