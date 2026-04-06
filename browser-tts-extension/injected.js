(() => {
  if (window.__localllmStreamingTtsHooked) {
    return;
  }
  window.__localllmStreamingTtsHooked = true;

  const originalFetch = window.fetch.bind(window);

  const shouldWatch = (url) => {
    return /\/(?:api\/)?chat\/completions/i.test(url || '');
  };

  const flattenContent = (value) => {
    if (typeof value === 'string') {
      return value;
    }
    if (Array.isArray(value)) {
      return value.map(flattenContent).join('');
    }
    if (!value || typeof value !== 'object') {
      return '';
    }
    if (typeof value.text === 'string') {
      return value.text;
    }
    if (typeof value.content === 'string') {
      return value.content;
    }
    return Object.values(value).map(flattenContent).join('');
  };

  const extractDeltaText = (payload) => {
    if (!payload || typeof payload !== 'object') {
      return '';
    }
    if (Array.isArray(payload.choices)) {
      return payload.choices
        .map((choice) => {
          if (choice?.delta?.content) {
            return flattenContent(choice.delta.content);
          }
          if (choice?.message?.content) {
            return flattenContent(choice.message.content);
          }
          return '';
        })
        .join('');
    }
    if (payload.delta?.content) {
      return flattenContent(payload.delta.content);
    }
    if (payload.message?.content) {
      return flattenContent(payload.message.content);
    }
    if (payload.content) {
      return flattenContent(payload.content);
    }
    return '';
  };

  const dispatch = (name, detail) => {
    window.dispatchEvent(new CustomEvent(name, { detail }));
  };

  const consumeStream = async (response, streamId) => {
    if (!response.body) {
      return;
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let doneSent = false;

    const sendDone = () => {
      if (doneSent) {
        return;
      }
      doneSent = true;
      dispatch('localllm-tts-done', { streamId });
    };

    const processSseChunk = (chunkText) => {
      const blocks = chunkText.split(/\r?\n\r?\n/);
      buffer = blocks.pop() || '';

      for (const block of blocks) {
        const lines = block.split(/\r?\n/);
        for (const line of lines) {
          if (!line.startsWith('data:')) {
            continue;
          }
          const data = line.slice(5).trim();
          if (!data) {
            continue;
          }
          if (data === '[DONE]') {
            sendDone();
            continue;
          }
          try {
            const parsed = JSON.parse(data);
            const text = extractDeltaText(parsed);
            if (text) {
              dispatch('localllm-tts-delta', { streamId, text });
            }
          } catch (_error) {
            // Ignore non-JSON blocks.
          }
        }
      }
    };

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        if (!value) {
          continue;
        }
        buffer += decoder.decode(value, { stream: true });
        processSseChunk(buffer);
      }

      if (buffer.trim()) {
        processSseChunk(`${buffer}\n\n`);
      }
    } catch (_error) {
      // Let the content script deal with partial streams.
    } finally {
      sendDone();
    }
  };

  window.fetch = async (...args) => {
    const response = await originalFetch(...args);
    try {
      const request = args[0];
      const url = typeof request === 'string' ? request : request?.url || '';
      if (!shouldWatch(url)) {
        return response;
      }

      const streamId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
      dispatch('localllm-tts-start', { streamId, url });
      consumeStream(response.clone(), streamId);
    } catch (_error) {
      // Ignore hook failures and preserve the original response.
    }
    return response;
  };
})();
