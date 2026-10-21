package TbNocNetworkPerf;

import Vector :: *;
import NocTypes :: *;
import Noc :: *;
import NocMetrics :: *;

typedef TMul#(MeshCols, MeshRows) MetricNodes;
typedef UInt#(TLog#(MetricNodes)) MetricNodeIndex;
typedef UInt#(TAdd#(SeqWidth, 1)) MetricSequence;

// B_N: independent injectors/collectors for every PE. A source starts its
// next message only after the final checked collection of its current one.
(* synthesize *)
module mkTbNocNetworkPerf(Empty);
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
      // Rank among all nodes except this source; every other node is reachable.
      UInt#(32) rank = unpack(randomWord) % fromInteger(nodes - 1);
      if (rank >= fromInteger(sourceId)) rank = rank + 1;
      return NodeAddr { x: truncate(pack(rank / fromInteger(rows))),
                        y: truncate(pack(rank % fromInteger(rows))) };
   endfunction

   Reg#(MetricCycle) cycle <- mkReg(0);
   Reg#(MetricCycle) quiet <- mkReg(0);
   Vector#(MetricNodes, Reg#(MetricSequence)) nextToSend <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(UInt#(32))) messageId <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(Bit#(32))) randomState = newVector;
   Vector#(MetricNodes, Reg#(MetricCount)) sent <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(MetricCount)) received <- replicateM(mkReg(0));
   Vector#(MetricNodes, Reg#(MetricCount)) sampled <- replicateM(mkReg(0));

   // Each destination owns its checker state and completion wires. A shared
   // writable counter/checker would serialize independent get methods.
   Vector#(MetricNodes, Vector#(MetricNodes, Reg#(MetricSequence))) expectedSeq
      <- replicateM(replicateM(mkReg(0)));
   Vector#(MetricNodes, Vector#(MetricNodes, PulseWire)) completed
      <- replicateM(replicateM(mkPulseWire));
   Vector#(MetricNodes, PulseWire) injected <- replicateM(mkPulseWire);

   for (Integer s = 0; s < nodes; s = s + 1) begin
      Bit#(32) seed = fromInteger(metricSeed) ^ (fromInteger(s + 1) * 32'h9e3779b9);
      randomState[s] <- mkReg(seed == 0 ? 1 : seed);

      // The sole writer of source control state handles injection and
      // completion events together, including simultaneous events.
      rule update_source;
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

   rule tick;
      cycle <= cycle + 1;
   endrule

   for (Integer x = 0; x < cols; x = x + 1) begin
      for (Integer y = 0; y < rows; y = y + 1) begin
         Integer id = x * rows + y;

         rule inject (nextToSend[id] < fromInteger(messagePackets) &&
                      (cycle < fromInteger(metricWarmupCycles + metricWindowCycles) ||
                       nextToSend[id] != 0));
            NodeAddr dst = destination(randomState[id], id);
            let pkt = metricPacket(nodeAt(x, y), dst, truncate(pack(nextToSend[id])),
                                   nextToSend[id] == fromInteger(messagePackets - 1),
                                   messageId[id]);
            noc.node[x][y].ma_put_packet(pkt);
            injected[id].send;
            sent[id] <= sent[id] + 1;
         endrule

         rule collect;
            let pkt <- noc.node[x][y].mav_get_packet();
            MetricNodeIndex sourceId = nodeIndex(pkt.src);
            MetricSequence seqNum = expectedSeq[id][sourceId];
            // Build the expected message from the source's current metadata.
            // No source advances that metadata until this checker completes it.
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
               $display("FAIL: B_N packet/order mismatch at (%0d,%0d), cycle %0d", x, y, cycle);
               $display("Expected: ", fshow(expected));
               $display("Received: ", fshow(pkt));
               $finish(1);
            end
            else begin
               if (pkt.is_last) begin
                  expectedSeq[id][sourceId] <= 0;
                  completed[id][sourceId].send;
               end
               else expectedSeq[id][sourceId] <= seqNum + 1;
               received[id] <= received[id] + 1;
               if (cycle >= fromInteger(metricWarmupCycles) &&
                   cycle < fromInteger(metricWarmupCycles + metricWindowCycles))
                  sampled[id] <= sampled[id] + 1;
            end
         endrule
      end
   end

   rule finish (cycle >= fromInteger(metricWarmupCycles + metricWindowCycles));
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

      if (drained) begin
         quiet <= quiet + 1;
         if (quiet == fromInteger(metricQuietCycles)) begin
            reportBandwidth("B_N", sampleCount, fromInteger(metricWindowCycles));
            $display("PASS: B_N seed=%0d warmup=%0d window=%0d accepted=%0d collected=%0d",
                     metricSeed, metricWarmupCycles, metricWindowCycles,
                     acceptedCount, collectedCount);
            $finish(0);
         end
      end
      else quiet <= 0;

      if (cycle >= fromInteger(metricWarmupCycles + metricWindowCycles + metricDrainTimeout)) begin
         $display("FAIL: B_N did not drain; accepted=%0d collected=%0d outstanding=%0d",
                  acceptedCount, collectedCount, acceptedCount - collectedCount);
         $display("FAIL: B_N bandwidth is not a valid passing result");
         $finish(1);
      end
   endrule
endmodule

endpackage
