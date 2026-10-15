# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# tts.ps1 —— 「念一句」的助手（由 tts.mjs 起进程调用，**一次一句，念完就退**）
#
# 为什么要它：Electron 自带的 Web Speech（speechSynthesis）在这台机器上**合成失败**
# （实测 `synthesis-failed`，音量 0 / 0.001 都失败，桌宠自己的页面上也一样），
# 而系统这条（System.Speech / SAPI5）是好的 —— 实测 `SAPI.SpVoice` 音量 0 也能合成成功。
# 于是 JS 版改走"系统引擎"，这个脚本就是那条路的最后一厘米。
#
# 为什么用 Windows PowerShell 5.1（不是 pwsh 7）：**它是 Windows 自带的**，不用用户装东西，
# 这和"JS 版不依赖 pwsh"的目标不冲突（我们依赖的是系统组件，不是用户要额外装的那份）。
#
# 协议（stdin/stdout 都是显式 UTF-8 —— 中文走 argv 会被系统码页弄成乱码，踩过）：
#   念一句：  -Speak -Voice <名字或空> -Rate <-10..10> -Volume <0..100>，正文从 **stdin** 读
#   列音色：  -ListVoices
#   输出：    一行 JSON。成功 {"ok":true,...}；失败 {"ok":false,"why":"..."}（**绝不静默**）
param(
  [switch]$Speak,
  [switch]$ListVoices,
  [string]$Voice = '',
  [int]$Rate = 0,
  [int]$Volume = 100
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8     # 否则 JSON 里的中文出去就是问号

function Write-Json($obj) {
  # 一行 JSON，便于调用方按行读（对象里都是 ASCII 键名 + 可能中文的值）
  [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress -Depth 5))
}

try {
  Add-Type -AssemblyName System.Speech
  $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $synth.SetOutputToDefaultAudioDevice()

  if ($ListVoices) {
    $names = @()
    foreach ($v in $synth.GetInstalledVoices()) {
      if ($v.Enabled) { $names += $v.VoiceInfo.Name }
    }
    Write-Json @{ ok = $true; backend = 'speech'; voices = $names }
    exit 0
  }

  if (-not $Speak) { Write-Json @{ ok = $false; why = '没有 -Speak / -ListVoices 参数' }; exit 2 }

  $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
  $text = $reader.ReadToEnd().Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { Write-Json @{ ok = $false; why = 'stdin 里没有要念的正文' }; exit 2 }

  if ($Volume -lt 0) { $Volume = 0 }
  if ($Volume -gt 100) { $Volume = 100 }
  if ($Rate -lt -10) { $Rate = -10 }
  if ($Rate -gt 10) { $Rate = 10 }
  $synth.Volume = $Volume
  $synth.Rate = $Rate

  # 音色：给了就用，但**必须存在**；不存在就直接说，不静默换人（用户改配置得看得见结果）
  $picked = ''
  if (-not [string]::IsNullOrWhiteSpace($Voice)) {
    $all = @()
    foreach ($v in $synth.GetInstalledVoices()) { if ($v.Enabled) { $all += $v.VoiceInfo.Name } }
    $hit = $all | Where-Object { $_ -eq $Voice } | Select-Object -First 1
    if (-not $hit) { $hit = $all | Where-Object { $_ -like "*$Voice*" } | Select-Object -First 1 }
    if (-not $hit) { Write-Json @{ ok = $false; why = "配的音色不存在：$Voice（可用：$($all -join ' / ')）" }; exit 3 }
    $synth.SelectVoice($hit)
    $picked = $hit
  } else {
    # 没指定：优先中文音色（桌宠说的是中文；系统默认可能是英文的 Zira）
    $all = @()
    foreach ($v in $synth.GetInstalledVoices()) { if ($v.Enabled) { $all += $v.VoiceInfo.Name } }
    $zh = $all | Where-Object { $_ -match 'Chinese|Huihui|Yaoyao|Kangkang|Xiaoxiao|zh-CN' } | Select-Object -First 1
    if ($zh) { $synth.SelectVoice($zh); $picked = $zh }
  }

  $synth.Speak($text)          # 同步说完再退：进程正常退出 = 真的念完了（调用方据此排队/打断）
  Write-Json @{ ok = $true; spoken = $true; voice = $picked; chars = $text.Length; volume = $Volume }
  exit 0
} catch {
  Write-Json @{ ok = $false; why = ($_.Exception.Message) }
  exit 1
}
