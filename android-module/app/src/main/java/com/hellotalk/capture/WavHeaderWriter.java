package com.hellotalk.capture;

import java.io.IOException;
import java.io.RandomAccessFile;

/**
 * Writes a standard 44-byte RIFF/WAVE header to a file.
 */
public class WavHeaderWriter {

    /**
     * Writes a complete WAV header at the beginning of the given file.
     *
     * @param filePath      path to the output .wav file
     * @param totalAudioLen total number of raw PCM bytes
     * @param sampleRate    sample rate in Hz (e.g. 44100)
     * @param channels      number of channels (1 = mono, 2 = stereo)
     * @param bitsPerSample bits per sample (8 or 16)
     */
    public static void writeHeader(String filePath, long totalAudioLen,
                                   int sampleRate, int channels, int bitsPerSample)
            throws IOException {
        long totalDataLen = totalAudioLen + 36; // 44 - 8 header bytes already counted
        int byteRate = sampleRate * channels * (bitsPerSample / 8);
        int blockAlign = channels * (bitsPerSample / 8);

        byte[] header = new byte[44];

        // RIFF chunk descriptor
        header[0] = 'R'; header[1] = 'I'; header[2] = 'F'; header[3] = 'F';
        writeInt32LE(header, 4, totalDataLen);
        header[8] = 'W'; header[9] = 'A'; header[10] = 'V'; header[11] = 'E';

        // fmt sub-chunk
        header[12] = 'f'; header[13] = 'm'; header[14] = 't'; header[15] = ' ';
        writeInt32LE(header, 16, 16);            // sub-chunk size (PCM = 16)
        writeInt16LE(header, 20, 1);             // audio format (1 = PCM)
        writeInt16LE(header, 22, channels);
        writeInt32LE(header, 24, sampleRate);
        writeInt32LE(header, 28, byteRate);
        writeInt16LE(header, 32, blockAlign);
        writeInt16LE(header, 34, bitsPerSample);

        // data sub-chunk
        header[36] = 'd'; header[37] = 'a'; header[38] = 't'; header[39] = 'a';
        writeInt32LE(header, 40, totalAudioLen);

        RandomAccessFile raf = new RandomAccessFile(filePath, "rw");
        try {
            raf.seek(0);
            raf.write(header);
        } finally {
            raf.close();
        }
    }

    private static void writeInt32LE(byte[] buf, int offset, long value) {
        buf[offset]     = (byte) (value & 0xFF);
        buf[offset + 1] = (byte) ((value >> 8) & 0xFF);
        buf[offset + 2] = (byte) ((value >> 16) & 0xFF);
        buf[offset + 3] = (byte) ((value >> 24) & 0xFF);
    }

    private static void writeInt16LE(byte[] buf, int offset, int value) {
        buf[offset]     = (byte) (value & 0xFF);
        buf[offset + 1] = (byte) ((value >> 8) & 0xFF);
    }
}
