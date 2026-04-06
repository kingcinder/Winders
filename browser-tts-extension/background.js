chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'local-streaming-tts') {
    return;
  }

  port.onMessage.addListener(async (message) => {
    if (!message || message.type !== 'synthesize' || !message.payload) {
      return;
    }

    const payload = message.payload;

    try {
      const response = await fetch(`${payload.ttsApiBaseUrl}/audio/speech`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${payload.ttsApiKey || 'not-needed'}`
        },
        body: JSON.stringify({
          model: payload.model,
          voice: payload.voice,
          input: payload.text,
          response_format: payload.responseFormat || 'pcm',
          speed: payload.speed || 1.0,
          stream_format: 'audio'
        })
      });

      if (!response.ok || !response.body) {
        const detail = await response.text().catch(() => response.statusText || 'stream unavailable');
        port.postMessage({ type: 'error', error: detail || 'TTS request failed.' });
        return;
      }

      const reader = response.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        if (value && value.byteLength > 0) {
          port.postMessage({ type: 'chunk', chunk: Array.from(value) });
        }
      }

      port.postMessage({ type: 'done' });
    } catch (error) {
      port.postMessage({ type: 'error', error: String(error) });
    }
  });
});
