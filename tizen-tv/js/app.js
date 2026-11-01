(function () {
  'use strict';

  // --- DOM Elements ---
  var standbyScreen = document.getElementById('standby-screen');
  var playerScreen = document.getElementById('player-screen');
  var connPill = document.getElementById('conn-pill');
  var connStatusText = document.getElementById('conn-status-text');
  var ipInputValue = document.getElementById('ip-input-value');
  var scanLog = document.getElementById('scan-log');
  var standbyNote = document.getElementById('standby-note');
  var standbyMicBar = document.getElementById('standby-mic-bar');
  var standbyModeBadge = document.getElementById('standby-mode-badge');
  var standbyPresetBadge = document.getElementById('standby-preset-badge');
  var standbyPitchBadge = document.getElementById('standby-pitch-badge');

  var tvVideo = document.getElementById('fk-tv-video');
  var ytIframeContainer = document.getElementById('fk-yt-iframe-container');
  var singerEl = document.getElementById('fk-singer');
  var tvPitchPill = document.getElementById('fk-tv-pitch-pill');
  var tvConnPill = document.getElementById('fk-tv-conn-pill');
  var debugEl = document.getElementById('fk-debug');
  var pitchCanvas = document.getElementById('fk-pitch-canvas');
  var micDot = document.getElementById('fk-mic-dot');
  var noteLabel = document.getElementById('fk-note-label');
  var modeLabel = document.getElementById('fk-mode-label');
  var scoreValue = document.getElementById('fk-score-value');
  var feedbackEl = document.getElementById('fk-feedback');
  var overallValue = document.getElementById('fk-overall-value');
  var processingEl = document.getElementById('fk-processing');
  var processingMsg = document.getElementById('fk-processing-msg');
  var celebrationEl = document.getElementById('fk-celebration');

  // --- State ---
  var ws = null;
  var connectedHost = null; // e.g. "192.168.1.5:8080"
  var defaultPort = 8080;
  var subnetPrefix = localStorage.getItem('fk_subnet_prefix') || '192.168.1.';
  var currentIpInput = localStorage.getItem('fk_last_phone_ip') || subnetPrefix;
  var isScanning = false;
  var autoScanTimer = null;
  var reconnectTimer = null;

  var currentVideoId = null;
  var currentPitchShift = 0;
  var usingYoutubeFallback = false;
  var ytPlayer = null;
  var ytTimeTimer = null;

  window._fkTrail = [];
  window._fkTrailMax = 640;

  // Focus navigation state for keypad
  var focusButtons = Array.prototype.slice.call(document.querySelectorAll('.tv-btn.focusable'));
  var focusedIndex = 12; // Default focus on "Conectar ao Celular"

  // --- Initialize ---
  function init() {
    registerTizenKeys();
    setupKeypad();
    updateFocus();
    updateIpDisplay();
    setupVideoEvents();

    // If opened directly from phone HTTP server (http://<PHONE_IP>:8080/tv)
    if (window.location.protocol.indexOf('http') === 0 && window.location.hostname) {
      var host = window.location.host || (window.location.hostname + ':' + defaultPort);
      currentIpInput = window.location.hostname;
      updateIpDisplay();
      connectToPhone(host);
    } else {
      // Try last known IP first, then auto-scan subnet
      var savedIp = localStorage.getItem('fk_last_phone_ip');
      if (savedIp && savedIp.split('.').length === 4) {
        tryPingHost(savedIp + ':' + defaultPort).then(function (ok) {
          if (ok) {
            connectToPhone(savedIp + ':' + defaultPort);
          } else {
            startSubnetScan();
          }
        });
      } else {
        startSubnetScan();
      }
    }

    // Periodic auto-scan while disconnected on standby screen
    autoScanTimer = setInterval(function () {
      if (!ws && !isScanning && playerScreen.style.display !== 'block') {
        startSubnetScan(true);
      }
    }, 7000);
  }

  // --- Tizen Hardware Keys ---
  function registerTizenKeys() {
    try {
      if (window.tizen && tizen.tvinputdevice) {
        var keys = [
          '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
          'MediaPlayPause', 'MediaPlay', 'MediaPause', 'MediaStop',
          'ColorF0Red', 'ColorF1Green', 'ColorF2Yellow', 'ColorF3Blue'
        ];
        for (var i = 0; i < keys.length; i++) {
          try { tizen.tvinputdevice.registerKey(keys[i]); } catch (_) {}
        }
      }
    } catch (_) {}

    document.addEventListener('keydown', function (e) {
      var code = e.keyCode;

      // Back / Return key on Samsung Remote (10009) or Escape (27)
      if (code === 10009 || code === 27) {
        if (celebrationEl.style.display === 'flex') {
          celebrationEl.style.display = 'none';
          e.preventDefault();
          return;
        }
        if (playerScreen.style.display === 'block') {
          stopAndReturnToStandby();
          sendWs({ type: 'tvStopped' });
          e.preventDefault();
          return;
        }
        try {
          if (window.tizen && tizen.application) {
            tizen.application.getCurrentApplication().exit();
          }
        } catch (_) {}
        return;
      }

      // Yellow button toggles debug bar
      if (code === 405) {
        debugEl.style.display = debugEl.style.display === 'none' ? 'block' : 'none';
        return;
      }

      // Media Play/Pause on TV Remote while playing
      if (playerScreen.style.display === 'block') {
        if (code === 10252 || code === 415 || code === 19 || code === 13) {
          if (celebrationEl.style.display === 'flex') {
            celebrationEl.style.display = 'none';
            return;
          }
          togglePlayPause();
          e.preventDefault();
        }
        return;
      }

      // Number keys 0-9 directly from remote
      if (code >= 48 && code <= 57) {
        handleKeypadInput(String(code - 48));
        e.preventDefault();
        return;
      }
      if (code >= 96 && code <= 105) {
        handleKeypadInput(String(code - 96));
        e.preventDefault();
        return;
      }

      // D-Pad navigation on standby screen
      if (code === 37) { // Left
        if (focusedIndex > 0) focusedIndex--;
        updateFocus();
        e.preventDefault();
      } else if (code === 39) { // Right
        if (focusedIndex < focusButtons.length - 1) focusedIndex++;
        updateFocus();
        e.preventDefault();
      } else if (code === 38) { // Up
        if (focusedIndex >= 12) focusedIndex -= 4;
        else if (focusedIndex >= 4) focusedIndex -= 4;
        updateFocus();
        e.preventDefault();
      } else if (code === 40) { // Down
        if (focusedIndex < 8) focusedIndex += 4;
        else if (focusedIndex < 12) focusedIndex = 12;
        updateFocus();
        e.preventDefault();
      } else if (code === 13) { // Enter
        var btn = focusButtons[focusedIndex];
        if (btn) btn.click();
        e.preventDefault();
      }
    });
  }

  function setupKeypad() {
    for (var i = 0; i < focusButtons.length; i++) {
      (function (idx, btn) {
        btn.addEventListener('click', function () {
          focusedIndex = idx;
          updateFocus();
          var k = btn.getAttribute('data-key');
          handleKeypadInput(k);
        });
      })(i, focusButtons[i]);
    }
  }

  function updateFocus() {
    for (var i = 0; i < focusButtons.length; i++) {
      if (i === focusedIndex) {
        focusButtons[i].classList.add('focused');
      } else {
        focusButtons[i].classList.remove('focused');
      }
    }
  }

  function updateIpDisplay() {
    ipInputValue.textContent = currentIpInput || subnetPrefix;
  }

  function handleKeypadInput(key) {
    if (key === 'backspace') {
      currentIpInput = currentIpInput.slice(0, -1);
      updateIpDisplay();
    } else if (key === 'connect') {
      var targetIp = resolveIpInput(currentIpInput);
      logScan('Conectando manualmente a ' + targetIp + ':' + defaultPort + '...');
      connectToPhone(targetIp + ':' + defaultPort);
    } else if (key === 'scan') {
      startSubnetScan(false);
    } else {
      if (currentIpInput.length < 21) {
        currentIpInput += key;
        updateIpDisplay();
      }
    }
  }

  function resolveIpInput(input) {
    var trimmed = (input || '').trim();
    // If user typed only 1-3 digits (Quick Code), prepend subnetPrefix
    if (/^\d{1,3}$/.test(trimmed)) {
      return subnetPrefix + trimmed;
    }
    if (trimmed.endsWith('.')) {
      return trimmed + '1';
    }
    return trimmed;
  }

  function logScan(msg) {
    if (scanLog) scanLog.innerHTML = msg;
  }

  // --- Auto-Discovery Scanner ---
  function tryPingHost(hostPort, timeoutMs) {
    return new Promise(function (resolve) {
      var timer = setTimeout(function () { resolve(null); }, timeoutMs || 650);
      fetch('http://' + hostPort + '/ping', { method: 'GET', mode: 'cors' })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          clearTimeout(timer);
          if (data && data.app === 'frank_karaoke') {
            resolve(data);
          } else {
            resolve(null);
          }
        })
        .catch(function () {
          clearTimeout(timer);
          resolve(null);
        });
    });
  }

  function startSubnetScan(silent) {
    if (isScanning) return;
    isScanning = true;
    if (!silent) {
      setConnectionStatus('searching', 'Escaneando rede Wi-Fi (' + subnetPrefix + 'x)...');
      logScan('🔍 Procurando celular com <b>Frank Karaoke</b> aberto na rede <b>' + subnetPrefix + '1–254</b>...');
    }

    var candidates = [];
    for (var i = 2; i <= 254; i++) {
      candidates.push(subnetPrefix + i + ':' + defaultPort);
    }

    var batchSize = 30;
    var index = 0;
    var foundHost = null;

    function nextBatch() {
      if (foundHost || ws) {
        isScanning = false;
        return;
      }
      if (index >= candidates.length) {
        isScanning = false;
        if (!ws && !silent) {
          setConnectionStatus('disconnected', 'Celular não encontrado automaticamente');
          logScan('Não encontramos o celular automaticamente. Verifique se o app <b>Frank Karaoke</b> está aberto no celular ou digite o IP acima.');
        }
        return;
      }

      var slice = candidates.slice(index, index + batchSize);
      index += batchSize;

      Promise.all(slice.map(function (hp) {
        return tryPingHost(hp, 600).then(function (res) {
          if (res && !foundHost) {
            foundHost = hp;
          }
        });
      })).then(function () {
        if (foundHost) {
          isScanning = false;
          var ipOnly = foundHost.split(':')[0];
          currentIpInput = ipOnly;
          localStorage.setItem('fk_last_phone_ip', ipOnly);
          updateIpDisplay();
          logScan('✅ Celular encontrado em <b>' + foundHost + '</b>! Conectando...');
          connectToPhone(foundHost);
        } else {
          nextBatch();
        }
      });
    }

    nextBatch();
  }

  // --- WebSocket Connection ---
  function setConnectionStatus(state, text) {
    connPill.className = 'conn-pill ' + state;
    connStatusText.textContent = text;
    if (tvConnPill) {
      if (state === 'connected') {
        tvConnPill.textContent = '🎤 MIC CONECTADO';
        tvConnPill.style.color = '#00ff88';
      } else {
        tvConnPill.textContent = '⚠️ RECONECTANDO MIC...';
        tvConnPill.style.color = '#ff9f43';
      }
    }
  }

  function connectToPhone(hostPort) {
    if (ws) {
      try { ws.close(); } catch (_) {}
      ws = null;
    }
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    var ipOnly = hostPort.split(':')[0];
    setConnectionStatus('searching', 'Conectando a ' + ipOnly + '...');

    try {
      var socket = new WebSocket('ws://' + hostPort + '/ws');

      socket.onopen = function () {
        ws = socket;
        connectedHost = hostPort;
        localStorage.setItem('fk_last_phone_ip', ipOnly);
        var parts = ipOnly.split('.');
        if (parts.length === 4) {
          subnetPrefix = parts[0] + '.' + parts[1] + '.' + parts[2] + '.';
          localStorage.setItem('fk_subnet_prefix', subnetPrefix);
        }
        setConnectionStatus('connected', 'Conectado ao Celular (' + ipOnly + ')');
        logScan('🟢 <b>Conectado ao celular (' + ipOnly + ')!</b> Escolha qualquer vídeo de karaokê no celular para começar na TV.');
        sendWs({ type: 'tvHello', device: 'Samsung Tizen TV' });
      };

      socket.onmessage = function (event) {
        try {
          var data = JSON.parse(event.data);
          handlePhoneMessage(data);
        } catch (_) {}
      };

      socket.onclose = function () {
        ws = null;
        setConnectionStatus('searching', 'Reconectando ao celular (' + ipOnly + ')...');
        reconnectTimer = setTimeout(function () {
          if (!ws && connectedHost) {
            connectToPhone(connectedHost);
          }
        }, 2500);
      };

      socket.onerror = function () {
        try { socket.close(); } catch (_) {}
      };
    } catch (e) {
      setConnectionStatus('disconnected', 'Erro ao conectar em ' + hostPort);
    }
  }

  function sendWs(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(JSON.stringify(obj));
      } catch (_) {}
    }
  }

  // --- Handle Messages from Phone ---
  function handlePhoneMessage(data) {
    if (!data || !data.type) return;

    switch (data.type) {
      case 'state':
        updateSettingsBadges(data);
        if (data.videoId && data.videoId !== currentVideoId) {
          startKaraokeVideo(data.videoId, data.title || '', data.pitchShift || 0);
        }
        break;

      case 'loadVideo':
        updateSettingsBadges(data);
        startKaraokeVideo(data.videoId, data.title || '', data.pitchShift || 0);
        break;

      case 'play':
        playCurrentVideo();
        break;

      case 'pause':
        pauseCurrentVideo();
        break;

      case 'restart':
        restartCurrentVideo();
        break;

      case 'seek':
        seekCurrentVideo(data.time || 0);
        break;

      case 'pitchShift':
        applyPitchShift(data.pitchShift || 0);
        break;

      case 'settings':
        updateSettingsBadges(data);
        break;

      case 'processing':
        showProcessing(!!data.show, data.message);
        break;

      case 'score':
        handleScoreUpdate(data);
        break;

      case 'celebration':
        showCelebration(data.score || 0);
        break;

      case 'stopVideo':
        stopAndReturnToStandby();
        break;
    }
  }

  function updateSettingsBadges(data) {
    if (data.modeName) {
      standbyModeBadge.textContent = 'Modo: ' + data.modeName;
      modeLabel.textContent = data.modeName;
    }
    if (data.presetLabel || data.preset) {
      var pName = data.presetLabel || formatPreset(data.preset);
      standbyPresetBadge.textContent = 'Mic: ' + pName;
    }
    if (typeof data.pitchShift === 'number') {
      applyPitchShift(data.pitchShift);
    }
    if (data.title && singerEl) {
      singerEl.textContent = '🎤 ' + data.title;
    }
  }

  function formatPreset(preset) {
    if (preset === 'externalMic') return 'Limpo';
    if (preset === 'partyMode') return 'Festa';
    return 'Sala';
  }

  // --- Video Playback Engine (Direct Stream + YouTube IFrame Fallback) ---
  function startKaraokeVideo(videoId, title, pitchShift) {
    if (!videoId) return;
    currentVideoId = videoId;
    currentPitchShift = pitchShift || 0;
    usingYoutubeFallback = false;

    standbyScreen.style.display = 'none';
    playerScreen.style.display = 'block';
    celebrationEl.style.display = 'none';

    singerEl.textContent = '🎤 ' + (title || 'Karaokê');
    resetHudScore();
    applyPitchShift(currentPitchShift);
    showProcessing(true, 'Carregando vídeo e preparando pontuação...');

    // Clean up any previous YT fallback player
    stopYtFallback();

    // Primary: Play via Phone's direct stream proxy (/video?v=VIDEO_ID)
    var streamUrl = 'http://' + connectedHost + '/video?v=' + encodeURIComponent(videoId) + '&t=' + Date.now();
    tvVideo.style.display = 'block';
    tvVideo.src = streamUrl;
    tvVideo.load();

    var playPromise = tvVideo.play();
    if (playPromise && playPromise.catch) {
      playPromise.catch(function (err) {
        console.warn('Direct video play error, switching to YT fallback:', err);
        startYtFallback(videoId);
      });
    }
  }

  function setupVideoEvents() {
    tvVideo.addEventListener('loadeddata', function () {
      showProcessing(false);
      applyPitchShift(currentPitchShift);
    });

    tvVideo.addEventListener('playing', function () {
      showProcessing(false);
      applyPitchShift(currentPitchShift);
      sendWs({ type: 'play' });
    });

    tvVideo.addEventListener('pause', function () {
      if (!tvVideo.ended) {
        sendWs({ type: 'pause' });
      }
    });

    tvVideo.addEventListener('seeked', function () {
      sendWs({ type: 'seeked', time: tvVideo.currentTime || 0 });
    });

    tvVideo.addEventListener('timeupdate', function () {
      if (!usingYoutubeFallback && tvVideo.currentTime > 0) {
        sendWs({
          type: 'timeupdate',
          time: tvVideo.currentTime,
          duration: tvVideo.duration || 0
        });
      }
    });

    tvVideo.addEventListener('ended', function () {
      sendWs({ type: 'ended', duration: tvVideo.duration || 0 });
    });

    tvVideo.addEventListener('error', function () {
      if (currentVideoId && !usingYoutubeFallback) {
        console.warn('Video element error, switching to YouTube IFrame fallback');
        startYtFallback(currentVideoId);
      }
    });
  }

  // Fallback: YouTube IFrame API if direct muxed stream is unavailable
  function startYtFallback(videoId) {
    usingYoutubeFallback = true;
    tvVideo.pause();
    tvVideo.removeAttribute('src');
    tvVideo.style.display = 'none';
    ytIframeContainer.style.display = 'block';
    ytIframeContainer.innerHTML = '<div id="yt- fallback-div"></div>';

    function createPlayer() {
      ytPlayer = new window.YT.Player('yt-fallback-div', {
        width: '100%',
        height: '100%',
        videoId: videoId,
        playerVars: {
          autoplay: 1,
          controls: 0,
          rel: 0,
          modestbranding: 1,
          playsinline: 1
        },
        events: {
          onReady: function (e) {
            showProcessing(false);
            e.target.playVideo();
            startYtTimeLoop();
          },
          onStateChange: function (e) {
            if (e.data === window.YT.PlayerState.PLAYING) {
              showProcessing(false);
              sendWs({ type: 'play' });
            } else if (e.data === window.YT.PlayerState.PAUSED) {
              sendWs({ type: 'pause' });
            } else if (e.data === window.YT.PlayerState.ENDED) {
              sendWs({ type: 'ended' });
            }
          }
        }
      });
    }

    if (window.YT && window.YT.Player) {
      createPlayer();
    } else {
      var tag = document.createElement('script');
      tag.src = 'https://www.youtube.com/iframe_api';
      window.onYouTubeIframeAPIReady = createPlayer;
      document.head.appendChild(tag);
    }
  }

  function startYtTimeLoop() {
    if (ytTimeTimer) clearInterval(ytTimeTimer);
    ytTimeTimer = setInterval(function () {
      if (usingYoutubeFallback && ytPlayer && ytPlayer.getCurrentTime) {
        var t = ytPlayer.getCurrentTime() || 0;
        var d = ytPlayer.getDuration ? (ytPlayer.getDuration() || 0) : 0;
        if (t > 0) {
          sendWs({ type: 'timeupdate', time: t, duration: d });
        }
      }
    }, 300);
  }

  function stopYtFallback() {
    if (ytTimeTimer) {
      clearInterval(ytTimeTimer);
      ytTimeTimer = null;
    }
    if (ytPlayer && ytPlayer.destroy) {
      try { ytPlayer.destroy(); } catch (_) {}
    }
    ytPlayer = null;
    ytIframeContainer.innerHTML = '';
    ytIframeContainer.style.display = 'none';
  }

  function playCurrentVideo() {
    if (usingYoutubeFallback && ytPlayer && ytPlayer.playVideo) {
      ytPlayer.playVideo();
    } else {
      tvVideo.play().catch(function () {});
    }
  }

  function pauseCurrentVideo() {
    if (usingYoutubeFallback && ytPlayer && ytPlayer.pauseVideo) {
      ytPlayer.pauseVideo();
    } else {
      tvVideo.pause();
    }
  }

  function togglePlayPause() {
    if (usingYoutubeFallback && ytPlayer && ytPlayer.getPlayerState) {
      var st = ytPlayer.getPlayerState();
      if (st === 1) ytPlayer.pauseVideo();
      else ytPlayer.playVideo();
    } else {
      if (tvVideo.paused) tvVideo.play().catch(function () {});
      else tvVideo.pause();
    }
  }

  function restartCurrentVideo() {
    celebrationEl.style.display = 'none';
    resetHudScore();
    if (usingYoutubeFallback && ytPlayer && ytPlayer.seekTo) {
      ytPlayer.seekTo(0, true);
      ytPlayer.playVideo();
    } else {
      tvVideo.currentTime = 0;
      tvVideo.play().catch(function () {});
    }
  }

  function seekCurrentVideo(seconds) {
    if (usingYoutubeFallback && ytPlayer && ytPlayer.seekTo) {
      ytPlayer.seekTo(seconds, true);
    } else {
      tvVideo.currentTime = seconds;
    }
  }

  function applyPitchShift(semitones) {
    currentPitchShift = semitones;
    var label = (semitones > 0 ? '+' : '') + semitones;
    standbyPitchBadge.textContent = 'Tom: ' + label;
    tvPitchPill.textContent = 'TOM: ' + label;

    if (!usingYoutubeFallback && tvVideo) {
      try {
        tvVideo.preservesPitch = false;
        tvVideo.webkitPreservesPitch = false;
        tvVideo.mozPreservesPitch = false;
        tvVideo.playbackRate = Math.pow(2, semitones / 12);
      } catch (_) {}
    }
  }

  function stopAndReturnToStandby() {
    currentVideoId = null;
    tvVideo.pause();
    tvVideo.removeAttribute('src');
    stopYtFallback();
    playerScreen.style.display = 'none';
    standbyScreen.style.display = 'flex';
  }

  function showProcessing(show, message) {
    if (show) {
      processingMsg.textContent = message || 'Carregando dados da música...';
      processingEl.style.display = 'flex';
    } else {
      processingEl.style.display = 'none';
    }
  }

  // --- Real-Time Scoring & Pitch Trail Rendering ---
  function resetHudScore() {
    window._fkTrail = [];
    scoreValue.textContent = '0';
    overallValue.textContent = '0';
    feedbackEl.textContent = '';
    noteLabel.textContent = '--';
    var ctx = pitchCanvas.getContext('2d');
    ctx.clearRect(0, 0, pitchCanvas.width, pitchCanvas.height);
  }

  function handleScoreUpdate(d) {
    var note = d.noteName || '--';
    var normRms = typeof d.normalizedRms === 'number' ? d.normalizedRms : 0;

    // Update Standby Mic Tester if on standby screen
    if (standbyScreen.style.display !== 'none') {
      standbyNote.textContent = note;
      standbyMicBar.style.width = Math.min(100, Math.round(normRms * 100)) + '%';
    }

    // 1. Update Note & Mic Dot
    noteLabel.textContent = note;
    if (normRms > 0.05) {
      var sz = 14 + normRms * 10;
      micDot.style.width = sz + 'px';
      micDot.style.height = sz + 'px';
      micDot.style.background = 'rgb(0,' + Math.round(180 + normRms * 75) + ',255)';
      micDot.style.boxShadow = '0 0 ' + Math.round(normRms * 28) + 'px rgba(0,210,255,' + (normRms * 0.85).toFixed(2) + ')';
    } else {
      micDot.style.width = '14px';
      micDot.style.height = '14px';
      micDot.style.background = '#333';
      micDot.style.boxShadow = 'none';
    }

    // 2. Update Score Box
    var liveScore = d.liveScore || 0;
    var overallScore = d.overallScore || 0;
    var streakCount = d.streakCount || 0;
    var mName = d.modeName || '';
    if (mName) modeLabel.textContent = mName;

    var isStreak = mName === 'Streak' || mName === 'Sequência';
    var color = '#ff6b6b', glow = '0 0 12px rgba(255,107,107,0.3)', feedback = '';

    if (isStreak && streakCount > 30) {
      color = '#ffd700'; glow = '0 0 35px rgba(255,215,0,0.8)';
      feedback = '🔥 ' + streakCount + 'x ON FIRE!';
    } else if (isStreak && streakCount > 15) {
      color = '#ffd700'; glow = '0 0 28px rgba(255,215,0,0.7)';
      feedback = '🔥 ' + streakCount + 'x COMBO!';
    } else if (isStreak && streakCount > 5) {
      color = '#ff9f43'; glow = '0 0 22px rgba(255,159,67,0.6)';
      feedback = '🔥 ' + streakCount + 'x streak';
    } else if (isStreak && streakCount === 0 && liveScore < 15) {
      color = '#ff6b6b'; glow = '0 0 15px rgba(255,107,107,0.3)';
      feedback = 'Combo perdido!';
    } else if (liveScore >= 95) {
      color = '#ffd700'; glow = '0 0 35px rgba(255,215,0,0.8)'; feedback = 'PERFEITO!';
    } else if (liveScore >= 85) {
      color = '#ffd700'; glow = '0 0 28px rgba(255,215,0,0.7)'; feedback = 'Incrível!';
    } else if (liveScore >= 75) {
      color = '#00ff88'; glow = '0 0 24px rgba(0,255,136,0.6)'; feedback = 'Mandando bem!';
    } else if (liveScore >= 65) {
      color = '#00ff88'; glow = '0 0 20px rgba(0,255,136,0.5)'; feedback = 'Soando bem!';
    } else if (liveScore >= 50) {
      color = '#00d2ff'; glow = '0 0 22px rgba(0,210,255,0.5)'; feedback = 'Continue assim!';
    } else if (liveScore >= 35) {
      color = '#00d2ff'; glow = '0 0 16px rgba(0,210,255,0.4)'; feedback = 'Aquecendo...';
    } else if (liveScore >= 20) {
      color = '#ff9f43'; glow = '0 0 16px rgba(255,159,67,0.5)'; feedback = 'Cante mais alto!';
    } else if (liveScore > 5) {
      color = '#ff6b6b'; glow = '0 0 14px rgba(255,107,107,0.4)'; feedback = 'Encontre a melodia!';
    }

    scoreValue.textContent = String(liveScore);
    scoreValue.style.color = color;
    scoreValue.style.textShadow = glow;
    feedbackEl.textContent = feedback;
    feedbackEl.style.color = color;

    overallValue.textContent = String(overallScore);
    if (overallScore >= 75) overallValue.style.color = 'rgba(0,255,136,0.85)';
    else if (overallScore >= 50) overallValue.style.color = 'rgba(0,210,255,0.85)';
    else overallValue.style.color = 'rgba(255,255,255,0.6)';

    // 3. Draw Pitch Trail Canvas
    var vp = typeof d.normalizedPitch === 'number' ? d.normalizedPitch : 0;
    var q = typeof d.frameScore === 'number' ? d.frameScore : 0;
    drawPitchTrail(vp, q);

    // 4. Update Debug Info
    if (typeof d.pitchHz === 'number') {
      debugEl.textContent = 'P:' + (d.primaryScore || 0).toFixed(2)
        + ' C:' + (d.confidence || 0).toFixed(2)
        + ' F:' + q.toFixed(2)
        + ' RMS:' + (d.rms || 0).toFixed(3)
        + ' ' + Math.round(d.pitchHz) + 'Hz stk:' + streakCount;
    }
  }

  function drawPitchTrail(vp, q) {
    if (!pitchCanvas) return;
    window._fkTrail.push({ p: vp, q: q });
    if (window._fkTrail.length > window._fkTrailMax) window._fkTrail.shift();

    var trail = window._fkTrail;
    var ctx = pitchCanvas.getContext('2d');
    var w = pitchCanvas.width;
    var h = pitchCanvas.height;
    var pad = 10;

    ctx.clearRect(0, 0, w, h);

    var nf = [130.81, 196, 261.63, 392, 523.25, 783.99];
    var nn = ['C3', 'G3', 'C4', 'G4', 'C5', 'G5'];
    var logMin = Math.log(100);
    var logRange = Math.log(800) - logMin;

    ctx.font = 'bold 12px system-ui';
    for (var n = 0; n < nf.length; n++) {
      var ny = (Math.log(nf[n]) - logMin) / logRange;
      if (ny < 0 || ny > 1) continue;
      var y = h - (ny * (h - 2 * pad)) - pad;
      ctx.strokeStyle = 'rgba(255,255,255,0.08)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(34, y);
      ctx.lineTo(w, y);
      ctx.stroke();
      ctx.fillStyle = 'rgba(255,255,255,0.3)';
      ctx.fillText(nn[n], 6, y + 4);
    }

    var sx = w - trail.length;
    var pvx = -1, pvy = -1;
    for (var i = 0; i < trail.length; i++) {
      var pt = trail[i];
      if (pt.p <= 0) {
        pvx = -1;
        continue;
      }
      var x = sx + i;
      var y = h - (pt.p * (h - 2 * pad)) - pad;
      var r = Math.round(255 * (1 - pt.q));
      var g = Math.round(220 * pt.q + 35);
      var col = 'rgb(' + r + ',' + g + ',80)';

      if (pvx >= 0 && Math.abs(pvy - y) < h * 0.4) {
        ctx.strokeStyle = col;
        ctx.lineWidth = 2.5;
        ctx.globalAlpha = 0.6;
        ctx.beginPath();
        ctx.moveTo(pvx, pvy);
        ctx.lineTo(x, y);
        ctx.stroke();
        ctx.globalAlpha = 1.0;
      }

      ctx.shadowColor = col;
      ctx.shadowBlur = pt.q > 0.5 ? 12 : 5;
      ctx.fillStyle = col;
      ctx.beginPath();
      ctx.arc(x, y, pt.q > 0.5 ? 4.5 : 2.5, 0, 6.283);
      ctx.fill();
      ctx.shadowBlur = 0;
      pvx = x;
      pvy = y;
    }
  }

  function showCelebration(score) {
    var phrase = 'Continue Praticando!', emoji = '🎤';
    if (score >= 90) { phrase = 'SUPERSTAR!'; emoji = '🌟'; }
    else if (score >= 75) { phrase = 'Muito Bem!'; emoji = '🎉'; }
    else if (score >= 50) { phrase = 'Boa Tentativa!'; emoji = '👏'; }
    else if (score >= 25) { phrase = 'Quase Lá!'; emoji = '💪'; }

    celebrationEl.innerHTML = '';
    celebrationEl.style.display = 'flex';

    var em = document.createElement('div');
    em.style.cssText = 'font-size:100px;margin-bottom:20px;animation:fkBounce 0.6s ease-out;';
    em.textContent = emoji;
    celebrationEl.appendChild(em);

    var ph = document.createElement('div');
    ph.style.cssText = 'font-size:60px;font-weight:800;color:#fff;margin-bottom:10px;'
      + 'text-shadow:0 0 35px rgba(255,215,0,0.6);animation:fkSlideUp 0.5s ease-out 0.2s both;';
    ph.textContent = phrase;
    celebrationEl.appendChild(ph);

    var sc = document.createElement('div');
    sc.style.cssText = 'font-size:130px;font-weight:900;line-height:1;margin:20px 0;'
      + 'animation:fkSlideUp 0.5s ease-out 0.4s both;';
    if (score >= 75) {
      sc.style.color = '#ffd700';
      sc.style.textShadow = '0 0 45px rgba(255,215,0,0.85),0 0 90px rgba(255,215,0,0.45)';
    } else if (score >= 50) {
      sc.style.color = '#00ff88';
      sc.style.textShadow = '0 0 35px rgba(0,255,136,0.65)';
    } else {
      sc.style.color = '#00d2ff';
      sc.style.textShadow = '0 0 25px rgba(0,210,255,0.55)';
    }
    sc.textContent = String(score);
    celebrationEl.appendChild(sc);

    var pt = document.createElement('div');
    pt.style.cssText = 'font-size:24px;color:rgba(255,255,255,0.55);letter-spacing:8px;'
      + 'animation:fkSlideUp 0.5s ease-out 0.5s both;';
    pt.textContent = 'PONTOS';
    celebrationEl.appendChild(pt);

    var colors = ['#ffd700', '#ff6b6b', '#00d2ff', '#00ff88', '#ff9f43', '#6c5ce7'];
    for (var i = 0; i < 36; i++) {
      var p = document.createElement('div');
      var sz = 5 + Math.random() * 7;
      var dl = Math.random() * 1.5;
      var cl = colors[Math.floor(Math.random() * colors.length)];
      p.style.cssText = 'position:absolute;left:' + (Math.random() * 100) + '%;top:' + (Math.random() * 100) + '%;'
        + 'width:' + sz + 'px;height:' + sz + 'px;border-radius:50%;background:' + cl + ';pointer-events:none;'
        + 'animation:fkSparkle 1.8s ease-out ' + dl.toFixed(2) + 's both;box-shadow:0 0 ' + (sz * 3) + 'px ' + cl + ';';
      celebrationEl.appendChild(p);
    }

    var hint = document.createElement('div');
    hint.style.cssText = 'margin-top:32px;font-size:18px;color:rgba(255,255,255,0.4);'
      + 'animation:fkSlideUp 0.5s ease-out 0.8s both;';
    hint.textContent = 'Escolha a próxima música no celular ou pressione OK/Voltar no controle';
    celebrationEl.appendChild(hint);
  }

  window.addEventListener('DOMContentLoaded', init);
})();
