// 录音用的 AudioWorklet 处理器（官方推荐的 ScriptProcessor 替代品）。
//
// 为什么走这条路：ScriptProcessorNode 在这台机器上会把渲染进程直接打崩
// （实测 `exitCode -1073741819` = 0xC0000005），而 MediaRecorder + decodeAudioData
// 又在"抬起"那一步崩。这里是最直的一条：音频线程上每 128 帧把 PCM 原样丢回主线程，
// **不编码、不解码**，中间没有任何容器格式。
class PetRecorder extends AudioWorkletProcessor {
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (ch && ch.length) {
      // 必须复制：这个 buffer 下一帧还会被复用
      this.port.postMessage(new Float32Array(ch));
    }
    return true;   // 一直活着，直到主线程把它断开
  }
}

registerProcessor('pet-recorder', PetRecorder);
