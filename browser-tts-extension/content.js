(async () => {
  const extensionSettings = await fetch(chrome.runtime.getURL('runtime-config.json'))
    .then((response) => response.json())
    .catch(() => ({
      frontend_url: 'http://127.0.0.1:3000',
      tts_api_base_url: 'http://127.0.0.1:8880/v1',
      tts_api_key: 'not-needed',
      tts_model: 'kokoro',
      tts_voice: 'af_bella',
      tts_response_format: 'pcm',
      tts_speed: 1.0,
      autoplay: true
    }));

  const state = {
    activeStreamId: null,
    carryText: '',
    sentenceQueue: [],
    workerActive: false,
    audioContext: null,
    playbackCursor: 0,
    pcmRemainder: new Uint8Array(0),
    autoplayEnabled: extensionSettings.autoplay !== false
  };

  const injectScript = () => {
    const script = document.createElement('script');
    script.src = chrome.runtime.getURL('injected.js');
    script.async = false;
    (document.head || document.documentElement).appendChild(script);
    script.remove();
  };

  const ensureAudioContext = async () => {
    if (!state.audioContext) {
      state.audioContext = new AudioContext({ sampleRate: 24000 });
      state.playbackCursor = state.audioContext.currentTime;
    }
    if (state.audioContext.state !== 'running') {
      try {
        await state.audioContext.resume();
      } catch (_error) {
        // Browser autoplay policies may defer resume until the next user gesture.
      }
    }
    return state.audioContext;
  };

  const appendToggle = () => {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Auto Voice On';
    button.style.position = 'fixed';
    button.style.right = '16px';
    button.style.bottom = '16px';
    button.style.zIndex = '2147483647';
    button.style.padding = '8px 12px';
    button.style.borderRadius = '999px';
    button.style.border = '1px solid #2f2f2f';
    button.style.background = '#111';
    button.style.color = '#fff';
    button.style.fontFamily = 'Segoe UI, sans-serif';
    button.style.fontSize = '12px';
    button.style.opacity = '0.85';
    button.addEventListener('click', async () => {
      state.autoplayEnabled = !state.autoplayEnabled;
      button.textContent = state.autoplayEnabled ? 'Auto Voice On' : 'Auto Voice Off';
      if (state.autoplayEnabled) {
        await ensureAudioContext();
      }
    });
    window.addEventListener('load', () => document.body.appendChild(button), { once: true });
  };

  const normalizeSentence = (sentence) => {
    return sentence.replace(/\s+/g, ' ').trim();
  };

  const popReadySentences = (finalFlush = false) => {
    const source = state.carryText;
    const regex = /([\s\S]*?(?:[.!?]+(?=\s|$)|\n+))/g;
    const sentences = [];
    let consumedLength = 0;
    let match;

    while ((match = regex.exec(source)) !== null) {
      const sentence = normalizeSentence(match[1]);
      if (sentence.length >= 8) {
        sentences.push(sentence);
        consumedLength = regex.lastIndex;
      }
    }

    state.carryText = source.slice(consumedLength);
    if (finalFlush) {
      const tail = normalizeSentence(state.carryText);
      if (tail) {
        sentences.push(tail);
      }
      state.carryText = '';
    }
    return sentences;
  };

  const schedulePcmChunk = async (chunk) => {
    const audioContext = await ensureAudioContext();
    if (!audioContext || !chunk || chunk.byteLength === 0) {
      return;
    }

    let combined = chunk;
    if (state.pcmRemainder.length > 0) {
      combined = new Uint8Array(state.pcmRemainder.length + chunk.length);
      combined.set(state.pcmRemainder, 0);
      combined.set(chunk, state.pcmRemainder.length);
    }

    if (combined.length < 2) {
      state.pcmRemainder = combined;
      return;
    }

    const evenLength = combined.length - (combined.length % 2);
    state.pcmRemainder = combined.slice(evenLength);
    const pcm = new Int16Array(combined.buffer.slice(combined.byteOffset, combined.byteOffset + evenLength));
    const samples = new Float32Array(pcm.length);
    for (let index = 0; index < pcm.length; index += 1) {
      samples[index] = pcm[index] / 32768;
    }

    const audioBuffer = audioContext.createBuffer(1, samples.length, 24000);
    audioBuffer.copyToChannel(samples, 0);
    const source = audioContext.createBufferSource();
    source.buffer = audioBuffer;
    source.connect(audioContext.destination);

    const startAt = Math.max(audioContext.currentTime + 0.02, state.playbackCursor);
    source.start(startAt);
    state.playbackCursor = startAt + audioBuffer.duration;
  };

  const speakSentence = (sentence) => {
    return new Promise((resolve, reject) => {
      const port = chrome.runtime.connect({ name: 'local-streaming-tts' });
      port.onMessage.addListener(async (message) => {
        if (!message) {
          return;
        }
        if (message.type === 'chunk') {
          const chunk = new Uint8Array(message.chunk);
          await schedulePcmChunk(chunk);
          return;
        }
        if (message.type === 'done') {
          port.disconnect();
          resolve();
          return;
        }
        if (message.type === 'error') {
          port.disconnect();
          reject(new Error(message.error || 'TTS synthesis failed.'));
        }
      });
      port.postMessage({
        type: 'synthesize',
        payload: {
          text: sentence,
          ttsApiBaseUrl: extensionSettings.tts_api_base_url,
          ttsApiKey: extensionSettings.tts_api_key,
          model: extensionSettings.tts_model,
          voice: extensionSettings.tts_voice,
          responseFormat: extensionSettings.tts_response_format,
          speed: extensionSettings.tts_speed
        }
      });
    });
  };

  const processQueue = async () => {
    if (state.workerActive || !state.autoplayEnabled) {
      return;
    }
    state.workerActive = true;
    try {
      while (state.sentenceQueue.length > 0 && state.autoplayEnabled) {
        const sentence = state.sentenceQueue.shift();
        if (!sentence) {
          continue;
        }
        await speakSentence(sentence);
      }
    } catch (_error) {
      // Leave autoplay available for the next response even if one request fails.
    } finally {
      state.workerActive = false;
    }
  };

  const queueSentences = (sentences) => {
    if (!state.autoplayEnabled) {
      return;
    }
    for (const sentence of sentences) {
      state.sentenceQueue.push(sentence);
    }
    processQueue();
  };

  const resetForStream = (streamId) => {
    state.activeStreamId = streamId;
    state.carryText = '';
    state.sentenceQueue = [];
    state.pcmRemainder = new Uint8Array(0);
    ensureAudioContext();
  };

  window.addEventListener('click', () => ensureAudioContext(), { passive: true });
  window.addEventListener('keydown', () => ensureAudioContext(), { passive: true });

  window.addEventListener('localllm-tts-start', (event) => {
    if (!state.autoplayEnabled) {
      return;
    }
    resetForStream(event.detail.streamId);
  });

  window.addEventListener('localllm-tts-delta', (event) => {
    if (!state.autoplayEnabled || event.detail.streamId !== state.activeStreamId) {
      return;
    }
    state.carryText += event.detail.text;
    queueSentences(popReadySentences(false));
  });

  window.addEventListener('localllm-tts-done', (event) => {
    if (!state.autoplayEnabled || event.detail.streamId !== state.activeStreamId) {
      return;
    }
    queueSentences(popReadySentences(true));
  });

  appendToggle();
  injectScript();
})();
