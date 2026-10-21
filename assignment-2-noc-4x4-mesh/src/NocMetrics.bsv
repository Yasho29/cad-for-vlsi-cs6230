package NocMetrics;

import Vector :: *;
import NocTypes :: *;

typedef UInt#(32) MetricCycle;
typedef UInt#(32) MetricCount;

Integer metricSeed = 42;
Integer metricWarmupCycles = 200;
Integer metricWindowCycles = 10000;
Integer metricQuietCycles = 50;
Integer metricDrainTimeout = 2000;

function Bit#(32) nextMetricRandom(Bit#(32) v);
   Bit#(32) x = v ^ (v << 13);
   x = x ^ (x >> 17);
   x = x ^ (x << 5);
   return (x == 0 ? 1 : x);
endfunction

function Bit#(PayloadWidth) makeMetricPayload(UInt#(32) msgId, Bit#(SeqWidth) seqNum, NodeAddr src);
   Bit#(32) headerWord = (zeroExtend(pack(src.x)) << 28) |
                         (zeroExtend(pack(src.y)) << 24) |
                         (pack(msgId) << 8) |
                         zeroExtend(seqNum);
   Vector#(8, Bit#(32)) words = replicate(headerWord);
   return pack(words);
endfunction

function NocPacket metricPacket(NodeAddr s, NodeAddr d, Bit#(SeqWidth) seqNum, Bool last, UInt#(32) msgId);
   return NocPacket {
      src: s,
      dst: d,
      seq_num: seqNum,
      is_last: last,
      payload: makeMetricPayload(msgId, seqNum, s)
   };
endfunction

function Action reportBandwidth(String tag, MetricCount samples, MetricCycle win);
   action
      UInt#(32) totalBytes = samples * fromInteger(valueOf(PayloadBytes));
      UInt#(32) th_x100 = (totalBytes * 100) / win;
      $display("REPORT: %s Bandwidth = %0d.%02d bytes/cycle (%0d packets, %0d bytes in %0d cycles)",
               tag, th_x100 / 100, th_x100 % 100, samples, totalBytes, win);
   endaction
endfunction

endpackage
