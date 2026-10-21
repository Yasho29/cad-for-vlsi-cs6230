package TbNoc;

import Vector       :: *;
import FIFOF        :: *;
import SpecialFIFOs :: *;
import ConfigReg    :: *;
import StmtFSM      :: *;
import NocTypes     :: *;
import Noc          :: *;
import NocMetrics   :: *;

typedef TMul#(MeshCols, MeshRows) MetricNodes;
typedef UInt#(TLog#(MetricNodes)) MetricNodeIndex;
typedef UInt#(TAdd#(SeqWidth, 1)) MetricSequence;

(* synthesize *)
module mkTbNoc (Empty);

   Integer cols = valueOf(MeshCols);
   Integer rows = valueOf(MeshRows);
   Integer nodes = valueOf(MetricNodes);
   Integer messagePackets = valueOf(TExp#(SeqWidth));
   Ifc_noc noc <- mkNoc;

   function NodeAddr nodeAt(Integer x, Integer y);
      return NodeAddr { x: fromInteger(x), y: fromInteger(y) };
   endfunction

   function MetricNodeIndex nodeIndex(NodeAddr addr);
      UInt#(32) x = zeroExtend(unpack(addr.x));
      UInt#(32) y = zeroExtend(unpack(addr.y));
      return truncate(x * fromInteger(rows) + y);
   endfunction

   function NodeAddr destination(Bit#(32) randomWord, Integer sourceId);
      UInt#(32) rank = unpack(randomWord) % fromInteger(nodes - 1);
      if (rank >= fromInteger(sourceId)) rank = rank + 1;
      return NodeAddr { x: truncate(pack(rank / fromInteger(rows))),
                        y: truncate(pack(rank % fromInteger(rows))) };
   endfunction

   Reg#(UInt#(32)) cycle <- mkReg(0);
   rule tick;
      cycle <= cycle + 1;
   endrule

   // -------------------------------------------------------------
   // Test Stages: 1 = L0, 2 = BS, 3 = AllPairs, 4 = Stall, 5 = BN
   // -------------------------------------------------------------
   Reg#(UInt#(4)) stage <- mkConfigReg(0);

   // L0 measurement registers
   Reg#(UInt#(32)) l0_start <- mkReg(0);
   Reg#(UInt#(32)) l0_cycles <- mkReg(0);

   // BS measurement registers
   Reg#(UInt#(32)) bs_first_cycle <- mkReg(0);
   Reg#(UInt#(32)) bs_last_cycle <- mkReg(0);
   Reg#(UInt#(8))  bs_pkts_recvd <- mkConfigReg(0);

   // Directed single-source FIFOs
   FIFOF#(NocPacket) directedIn <- mkFIFOF;
   FIFOF#(NocPacket) directedExpected <- mkUGSizedFIFOF(64);
   Reg#(UInt#(32)) directedSent <- mkReg(0);
   Reg#(UInt#(32)) directedOut <- mkConfigReg(0);

   Vector#(MeshCols, Vector#(MeshRows, Reg#(Bool))) collecting <- replicateM(replicateM(mkConfigReg(True)));

   for (Integer x = 0; x < cols; x = x + 1) begin
      for (Integer y = 0; y < rows; y = y + 1) begin
         rule put_directed (stage >= 1 && stage <= 4 && directedIn.first.src == nodeAt(x, y));
            noc.node[x][y].ma_put_packet(directedIn.first);
            directedIn.deq;
         endrule

         rule get_directed (stage >= 1 && stage <= 4 && collecting[x][y]);
            let p <- noc.node[x][y].mav_get_packet;
            if (p != directedExpected.first) begin
               $display("FAIL directed: mismatch at (%0d,%0d)", x, y);
               $finish(1);
            end
            directedExpected.deq;
            directedOut <= directedOut + 1;
            if (stage == 1) begin
               l0_cycles <= cycle - l0_start;
            end
            else if (stage == 2) begin
               if (bs_pkts_recvd == 0) bs_first_cycle <= cycle;
               if (p.is_last) bs_last_cycle <= cycle;
               bs_pkts_recvd <= bs_pkts_recvd + 1;
            end
         endrule
      end
   end

   // -------------------------------------------------------------
   // Continuous Saturation BN Network Throughput
   // -------------------------------------------------------------
   Reg#(MetricCycle) bnCycle <- mkReg(0);
   Reg#(MetricCycle) quiet <- mkReg(0);
   Vector#(MetricNodes, Reg#(MetricSequence)) nextToSend <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(UInt#(32))) messageId <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(Bit#(32))) randomState = newVector;
   Vector#(MetricNodes, Reg#(MetricCount)) sent <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(MetricCount)) received <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(MetricCount)) sampled <- replicateM(mkReg(0));

   Vector#(MetricNodes, Vector#(MetricNodes, Reg#(MetricSequence))) expectedSeq <- replicateM(replicateM(mkReg(0)));
   Vector#(MetricNodes, Vector#(MetricNodes, PulseWire)) completed <- replicateM(replicateM(mkPulseWire));
   Vector#(MetricNodes, PulseWire) injected <- replicateM(mkPulseWire);

   for (Integer s = 0; s < nodes; s = s + 1) begin
      Bit#(32) seed = fromInteger(metricSeed) ^ (fromInteger(s + 1) * 32'h9e3779b9);
      randomState[s] <- mkReg(seed == 0 ? 1 : seed);

      rule update_source (stage == 5);
         Bool done = False;
         for (Integer d = 0; d < nodes; d = d + 1)
            if (completed[d][s]) done = True;
         if (done) begin
            nextToSend[s] <= 0;
            messageId[s] <= messageId[s] + 1;
            randomState[s] <= nextMetricRandom(randomState[s]);
         end
         else if (injected[s]) nextToSend[s] <= nextToSend[s] + 1;
      endrule
   end

   for (Integer x = 0; x < cols; x = x + 1) begin
      for (Integer y = 0; y < rows; y = y + 1) begin
         Integer id = x * rows + y;

         rule inject (stage == 5 && nextToSend[id] < fromInteger(messagePackets) &&
                      (bnCycle < fromInteger(metricWarmupCycles + metricWindowCycles) ||
                       nextToSend[id] != 0));
            NodeAddr dst = destination(randomState[id], id);
            let pkt = metricPacket(nodeAt(x, y), dst, truncate(pack(nextToSend[id])),
                                   nextToSend[id] == fromInteger(messagePackets - 1),
                                   messageId[id]);
            noc.node[x][y].ma_put_packet(pkt);
            injected[id].send;
            sent[id] <= sent[id] + 1;
         endrule

         rule collect (stage == 5);
            let pkt <- noc.node[x][y].mav_get_packet();
            MetricNodeIndex sourceId = nodeIndex(pkt.src);
            MetricSequence seqNum = expectedSeq[id][sourceId];
            UInt#(32) rank = unpack(randomState[sourceId]) % fromInteger(nodes - 1);
            if (rank >= zeroExtend(sourceId)) rank = rank + 1;
            NodeAddr expectedDst = NodeAddr {
               x: truncate(pack(rank / fromInteger(rows))),
               y: truncate(pack(rank % fromInteger(rows)))
            };
            let expected = metricPacket(pkt.src, expectedDst, truncate(pack(seqNum)),
                                        seqNum == fromInteger(messagePackets - 1),
                                        messageId[sourceId]);
            if (pkt.dst != nodeAt(x, y) || pkt.src == pkt.dst || pkt != expected) begin
               $display("FAIL: BN packet mismatch at (%0d,%0d)", x, y);
               $finish(1);
            end
            else begin
               if (pkt.is_last) begin
                  expectedSeq[id][sourceId] <= 0;
                  completed[id][sourceId].send;
               end
               else expectedSeq[id][sourceId] <= seqNum + 1;
               received[id] <= received[id] + 1;
               if (bnCycle >= fromInteger(metricWarmupCycles) &&
                   bnCycle < fromInteger(metricWarmupCycles + metricWindowCycles))
                  sampled[id] <= sampled[id] + 1;
            end
         endrule
      end
   end

   rule tickBn (stage == 5);
      bnCycle <= bnCycle + 1;
   endrule

   // -------------------------------------------------------------
   // Test Routines
   // -------------------------------------------------------------
   function Action sendDir(NodeAddr s, NodeAddr d, Bit#(SeqWidth) sq, Bool last);
      action
         let p = metricPacket(s, d, sq, last, 0);
         directedIn.enq(p);
         directedExpected.enq(p);
         directedSent <= directedSent + 1;
      endaction
   endfunction

   Stmt awaitDrain = seq
      await(directedOut == directedSent);
      delay(20);
   endseq;

   NodeAddr corner = nodeAt(cols - 1, rows - 1);
   Reg#(UInt#(16)) i  <- mkRegU;
   Reg#(UInt#(16)) sx <- mkRegU;
   Reg#(UInt#(16)) sy <- mkRegU;
   Reg#(UInt#(16)) dx <- mkRegU;
   Reg#(UInt#(16)) dy <- mkRegU;

   Stmt runL0 = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] TEST 1: Zero-Load Latency (L0) from (0,0) to (%0d,%0d)", cycle, corner.x, corner.y);
      stage <= 1;
      action
         l0_start <= cycle;
         sendDir(nodeAt(0, 0), corner, 0, True);
      endaction
      awaitDrain;
      $display("[%0d] TEST 1 passed. Measured L0 = %0d cycles", cycle, l0_cycles);
   endseq;

   Stmt runBS = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] TEST 2: Stream Bandwidth (BS) from (0,0) to (%0d,%0d) (8-packet message)", cycle, corner.x, corner.y);
      stage <= 2;
      bs_pkts_recvd <= 0;
      for (i <= 0; i < 8; i <= i + 1)
         sendDir(nodeAt(0, 0), corner, truncate(pack(i)), i == 7);
      awaitDrain;
      action
         UInt#(32) span = bs_last_cycle - bs_first_cycle + 1;
         $display("[%0d] TEST 2 passed. 256 bytes in %0d cycles (first: %0d, last: %0d)",
                  cycle, span, bs_first_cycle, bs_last_cycle);
         $display("      Measured BS = %0d.%0d bytes/cycle", 256 / span, ((256 * 10) / span) % 10);
      endaction
   endseq;

   Stmt runAllPairs = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] TEST 3: All-Pairs Exhaustive Delivery (G1, G2, G3)", cycle);
      stage <= 3;
      for (sx <= 0; sx < fromInteger(cols); sx <= sx + 1)
         for (sy <= 0; sy < fromInteger(rows); sy <= sy + 1)
            for (dx <= 0; dx < fromInteger(cols); dx <= dx + 1)
               for (dy <= 0; dy < fromInteger(rows); dy <= dy + 1)
                  if (sx != dx || sy != dy) seq
                     sendDir(NodeAddr { x: truncate(pack(sx)), y: truncate(pack(sy)) },
                             NodeAddr { x: truncate(pack(dx)), y: truncate(pack(dy)) }, 0, True);
                     await(directedOut == directedSent);
                  endseq
      awaitDrain;
      $display("[%0d] TEST 3 passed (all 240 pairs delivered in order)", cycle);
   endseq;

   Stmt runBackpressure = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] TEST 4: Back-pressure and Network Draining", cycle);
      stage <= 4;
      collecting[cols-1][rows-1] <= False;
      par
         for (i <= 0; i < 8; i <= i + 1)
            sendDir(nodeAt(0, 0), corner, truncate(pack(i)), i == 7);
         seq
            delay(500);
            collecting[cols-1][rows-1] <= True;
         endseq
      endpar
      awaitDrain;
      $display("[%0d] TEST 4 passed", cycle);
   endseq;

   Stmt runBN = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] TEST 5: Network Throughput (BN) under Full Saturation", cycle);
      $display("      All 16 PEs hammering network with 8-packet messages to random destinations");
      stage <= 5;
      await(bnCycle >= fromInteger(metricWarmupCycles + metricWindowCycles));
      action
         Bool drained = True;
         MetricCount acceptedCount = 0;
         MetricCount collectedCount = 0;
         MetricCount sampleCount = 0;
         for (Integer n = 0; n < nodes; n = n + 1) begin
            if (nextToSend[n] != 0) drained = False;
            acceptedCount = acceptedCount + sent[n];
            collectedCount = collectedCount + received[n];
            sampleCount = sampleCount + sampled[n];
         end
         if (acceptedCount != collectedCount) drained = False;
         if (drained) quiet <= quiet + 1;
      endaction
      while (quiet < fromInteger(metricQuietCycles)) seq
         action
            Bool drained = True;
            MetricCount acceptedCount = 0;
            MetricCount collectedCount = 0;
            for (Integer n = 0; n < nodes; n = n + 1) begin
               if (nextToSend[n] != 0) drained = False;
               acceptedCount = acceptedCount + sent[n];
               collectedCount = collectedCount + received[n];
            end
            if (acceptedCount == collectedCount && drained) quiet <= quiet + 1;
            else quiet <= 0;
         endaction
         delay(1);
      endseq
      stage <= 6;
   endseq;

   mkAutoFSM(seq
      runL0;
      runBS;
      runAllPairs;
      runBackpressure;
      runBN;
      $display("================================================================");
      $display("TABLE 2 PERFORMANCE METRICS SUMMARY:");
      $display("  L0 (Zero-load latency)      : %0d cycles", l0_cycles);
      $display("  BR (Router peak bandwidth)  : 160 bytes/cycle (5 ports x 32 bytes)");
      action
         UInt#(32) span = bs_last_cycle - bs_first_cycle + 1;
         $display("  BS (Stream bandwidth)       : %0d.%0d bytes/cycle", 256 / span, ((256 * 10) / span) % 10);
      endaction
      action
         MetricCount sampleCount = 0;
         for (Integer n = 0; n < nodes; n = n + 1)
            sampleCount = sampleCount + sampled[n];
         reportBandwidth("B_N", sampleCount, fromInteger(metricWindowCycles));
      endaction
      $display("================================================================");
      $display("[%0d] ALL NOC TESTS PASSED SUCCESSFULLY!", cycle);
      $display("================================================================");
   endseq);

endmodule

endpackage
