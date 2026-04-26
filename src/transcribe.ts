import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

import { readEnvFile } from './env.js';
import { log } from './log.js';

const execFileP = promisify(execFile);

const envCfg = readEnvFile(['NANOCLAW_WHISPER_BIN', 'NANOCLAW_WHISPER_MODEL', 'NANOCLAW_WHISPER_LANG', 'NANOCLAW_WHISPER_TIMEOUT_MS']);
const WHISPER_BIN = process.env.NANOCLAW_WHISPER_BIN || envCfg.NANOCLAW_WHISPER_BIN;
const WHISPER_MODEL = process.env.NANOCLAW_WHISPER_MODEL || envCfg.NANOCLAW_WHISPER_MODEL;
const WHISPER_LANG = process.env.NANOCLAW_WHISPER_LANG || envCfg.NANOCLAW_WHISPER_LANG || 'auto';
const WHISPER_TIMEOUT_MS = parseInt(
  process.env.NANOCLAW_WHISPER_TIMEOUT_MS || envCfg.NANOCLAW_WHISPER_TIMEOUT_MS || '180000',
  10,
);

export function isTranscriptionEnabled(): boolean {
  return !!(WHISPER_BIN && WHISPER_MODEL);
}

/**
 * Transcribe an audio file using whisper.cpp. Returns null if transcription
 * is not configured, the file is missing, or the run fails — never throws.
 *
 * Pipeline: ffmpeg → 16kHz mono PCM WAV → whisper-cli stdout. Caller is
 * expected to be on the host (not inside an agent container).
 */
export async function transcribeAudio(absolutePath: string): Promise<string | null> {
  if (!isTranscriptionEnabled()) return null;

  try {
    await fs.access(absolutePath);
  } catch {
    return null;
  }

  const tmpWav = path.join(
    path.dirname(absolutePath),
    `.${path.basename(absolutePath)}.${process.pid}.wav`,
  );
  const startMs = Date.now();
  try {
    await execFileP(
      'ffmpeg',
      ['-y', '-loglevel', 'error', '-i', absolutePath, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', tmpWav],
      { timeout: WHISPER_TIMEOUT_MS },
    );
    const { stdout } = await execFileP(
      WHISPER_BIN!,
      ['-m', WHISPER_MODEL!, '-l', WHISPER_LANG, '-nt', '--no-prints', '-f', tmpWav],
      { timeout: WHISPER_TIMEOUT_MS, maxBuffer: 10 * 1024 * 1024 },
    );
    const text = stdout.trim().replace(/\s+/g, ' ');
    if (!text) return null;
    log.info('Audio transcribed', {
      path: path.basename(absolutePath),
      durationMs: Date.now() - startMs,
      chars: text.length,
    });
    return text;
  } catch (err) {
    log.warn('Transcription failed', {
      path: path.basename(absolutePath),
      err: (err as Error).message,
    });
    return null;
  } finally {
    await fs.unlink(tmpWav).catch(() => {});
  }
}
