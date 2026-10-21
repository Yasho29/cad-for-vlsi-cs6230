// ============================================================================
//  CAD for VLSI -- Assignment 2: basic tests for mkNoc
//
//  A few directed tests to get you started.  They drive mkNoc only through
//  Ifc_noc, exactly as our test bench does, and stop at the first failure.
//
//    1. single     one packet from (0,0) to (3,3) in an idle network
//    2. all pairs  one packet between every ordered pair of nodes, one at a time
//    3. messages   messages of 1, 2, ..., 8 packets from (0,0) to (3,3)
//    4. stall      (3,3) stops collecting while (0,0) sends it an 8-packet
//                  message, then starts again; the network must hold every
//                  packet and then drain, in order
//
//  These are NOT the tests we grade with.  We grade with many more, including
//  many PEs sending at once, random traffic and back-pressure, and the extreme
//  load test.  Passing these is a starting point, not a promise of marks, and
//  this file is not the NoC test bench you have to submit: write your own,
//  and feel free to start from this one.
//
//  To keep the checking simple, only one source sends to one destination at
//  any time, so every packet must come out in exactly the order it was sent.
//  Tests with several sources at once need a smarter checker.
//
//  Build and run, next to your Noc.bsv, NocRouter.bsv and NocTypes.bsv:
//     mkdir -p build
//     bsc -u -sim -bdir build -simdir build -info-dir build -g mkTbNocBasic TbNocBasic.bsv
//     bsc -sim -bdir build -simdir build -e mkTbNocBasic -o simTbNocBasic
//     ./simTbNocBasic
//
// ** Disclaimer: This test setup was generated using an AI agent and serves only as a starter
// for your own test bench. Please exercise caution and sound judgement when using it. **
// ============================================================================
package TbNocBasic;

import Vector    :: *;
import FIFOF     :: *;
import ConfigReg :: *;
import StmtFSM   :: *;
import NocTypes  :: *;
import Noc       :: *;

Integer cols        = valueOf(MeshCols);
Integer rows        = valueOf(MeshRows);
Integer maxPkts     = valueOf(TExp#(SeqWidth));   // longest message, in packets
Integer stallCycles = 1000;    // how long (3,3) stops collecting in test 4
Integer quietCycles = 100;     // after a test, nothing more may come out for this long
Integer timeout     = 10000;   // fail if nothing comes out for this long while a packet is due

function NodeAddr node (Integer x, Integer y) =
   NodeAddr { x: fromInteger(x), y: fromInteger(y) };

// A payload that differs from packet to packet (xorshift32 of a serial
// number), so that a lost, duplicated, swapped or corrupted packet shows up
// when the packet that comes out is compared with the one that went in.
function Bit#(PayloadWidth) makePayload (Bit#(32) serial);
   Vector#(TDiv#(TAdd#(PayloadWidth, 31), 32), Bit#(32)) w = newVector;
   Bit#(32) v = (serial << 1) | 1;
   for (Integer i = 0; i < valueOf(TDiv#(TAdd#(PayloadWidth, 31), 32)); i = i + 1) begin
      v = v ^ (v << 13);
      v = v ^ (v >> 17);
      v = v ^ (v << 5);
      w[i] = v;
   end
   return truncate(pack(w));
endfunction

function Fmt showPacket (NocPacket p) =
   $format("src (%0d,%0d) dst (%0d,%0d) seq %0d is_last %0d payload %h",
           p.src.x, p.src.y, p.dst.x, p.dst.y, p.seq_num, pack(p.is_last), p.payload);

(* synthesize *)
module mkTbNocBasic (Empty);

   Ifc_noc noc <- mkNoc;

   Reg#(UInt#(32)) cycle <- mkReg(0);
   rule tick;
      cycle <= cycle + 1;
   endrule

   function Action fail (Fmt msg) =
      action
         $display($format("[%0d] FAIL: ", cycle) + msg);
         $finish(0);
      endaction;

   // ------------------------------------------------------------ inputs --
   // send() queues a packet here; the rule for its source node puts it in.
   FIFOF#(NocPacket) toSend <- mkFIFOF;

   for (Integer x = 0; x < cols; x = x + 1)
      for (Integer y = 0; y < rows; y = y + 1)
         rule put_in (toSend.first.src == node(x, y));
            noc.node[x][y].ma_put_packet(toSend.first);
            toSend.deq;
         endrule

   // ----------------------------------------------------------- outputs --
   // Packets sent and not yet come out, oldest first.  Only one source sends
   // to one destination at a time, so the next packet to come out anywhere
   // must be the head of this queue, at its dst.  (64 entries is far more than
   // these tests ever have in flight.)
   FIFOF#(NocPacket) expected <- mkUGSizedFIFOF(64);

   // Every node collects whatever comes out, unless a test switches it off,
   // and checks it against the head of expected.
   Vector#(MeshCols, Vector#(MeshRows, Reg#(Bool))) collecting <- replicateM(replicateM(mkReg(True)));
   Vector#(MeshCols, Vector#(MeshRows, PulseWire))  matched    <- replicateM(replicateM(mkPulseWire));

   for (Integer x = 0; x < cols; x = x + 1)
      for (Integer y = 0; y < rows; y = y + 1)
         rule take_out (collecting[x][y]);
            let p <- noc.node[x][y].mav_get_packet;
            if (!expected.notEmpty || expected.first.dst != node(x, y))
               fail($format("a packet came out at (%0d,%0d), where none is due: ", x, y)
                    + showPacket(p));
            else if (p != expected.first)
               fail($format("wrong packet came out at (%0d,%0d)\n    expected: ", x, y)
                    + showPacket(expected.first) + $format("\n    received: ") + showPacket(p));
            else
               matched[x][y].send;
         endrule

   // ----------------------------------------------------------- checker --
   Reg#(Bit#(32))    serial   <- mkReg(0);
   Reg#(UInt#(32))   nSent    <- mkReg(0);
   // A ConfigReg, so that the test sequence can read it while the checker
   // writes it, without forcing an order between their rules.
   Reg#(UInt#(32))   nOut     <- mkConfigReg(0);
   Reg#(UInt#(32))   idle     <- mkReg(0);

   (* fire_when_enabled, no_implicit_conditions *)
   rule check;
      Bool anyMatch = False;
      for (Integer x = 0; x < cols; x = x + 1)
         for (Integer y = 0; y < rows; y = y + 1)
            if (matched[x][y]) anyMatch = True;

      if (anyMatch) begin
         expected.deq;
         nOut <= nOut + 1;
         idle <= 0;
      end
      else if (expected.notEmpty) begin
         if (idle == fromInteger(timeout))
            fail($format("nothing has come out for %0d cycles; still waiting for ", timeout)
                 + showPacket(expected.first));
         idle <= idle + 1;
      end
      else
         idle <= 0;
   endrule

   // ------------------------------------------------------------- tests --
   function Action send (NodeAddr src, NodeAddr dst, Bit#(SeqWidth) seq_num, Bool is_last) =
      action
         NocPacket p = NocPacket { src: src, dst: dst, is_last: is_last,
                                   seq_num: seq_num, payload: makePayload(serial) };
         toSend.enq(p);
         expected.enq(p);
         serial <= serial + 1;
         nSent  <= nSent + 1;
      endaction;

   // Wait until every packet sent has come out, then make sure nothing else does.
   Stmt drain = seq
      await(nOut == nSent);
      delay(fromInteger(quietCycles));
   endseq;

   NodeAddr corner = node(cols - 1, rows - 1);   // (3,3)

   Reg#(UInt#(16)) sx  <- mkRegU;
   Reg#(UInt#(16)) sy  <- mkRegU;
   Reg#(UInt#(16)) dx  <- mkRegU;
   Reg#(UInt#(16)) dy  <- mkRegU;
   Reg#(UInt#(16)) len <- mkRegU;
   Reg#(UInt#(16)) i   <- mkRegU;

   Stmt testSingle = seq
      $display("[%0d] TEST 1: one packet from (0,0) to (%0d,%0d)", cycle, corner.x, corner.y);
      send(node(0, 0), corner, 0, True);
      drain;
      $display("[%0d] TEST 1 passed", cycle);
   endseq;

   Stmt testAllPairs = seq
      $display("[%0d] TEST 2: one packet between every pair of nodes, one at a time", cycle);
      for (sx <= 0; sx < fromInteger(cols); sx <= sx + 1)
         for (sy <= 0; sy < fromInteger(rows); sy <= sy + 1)
            for (dx <= 0; dx < fromInteger(cols); dx <= dx + 1)
               for (dy <= 0; dy < fromInteger(rows); dy <= dy + 1)
                  if (sx != dx || sy != dy) seq
                     send(NodeAddr { x: truncate(pack(sx)), y: truncate(pack(sy)) },
                          NodeAddr { x: truncate(pack(dx)), y: truncate(pack(dy)) }, 0, True);
                     await(nOut == nSent);
                  endseq
      drain;
      $display("[%0d] TEST 2 passed", cycle);
   endseq;

   Stmt testMessages = seq
      $display("[%0d] TEST 3: messages of 1 to %0d packets from (0,0) to (%0d,%0d)",
               cycle, maxPkts, corner.x, corner.y);
      for (len <= 1; len <= fromInteger(maxPkts); len <= len + 1) seq
         for (i <= 0; i < len; i <= i + 1)
            send(node(0, 0), corner, truncate(pack(i)), i == len - 1);
         await(nOut == nSent);   // A4: the next message starts once this one is out
      endseq
      drain;
      $display("[%0d] TEST 3 passed", cycle);
   endseq;

   // Node (x,y) stops collecting while (0,0) sends it an 8-packet message.
   // The sends and the stall run in parallel: once the network is full,
   // ma_put_packet at (0,0) must stop accepting until (x,y) collects again.
   function Stmt stallAt (Integer x, Integer y) = seq
      $display("[%0d]   (%0d,%0d) stops collecting for %0d cycles while (0,0) sends it %0d packets",
               cycle, x, y, stallCycles, maxPkts);
      collecting[x][y] <= False;
      par
         for (i <= 0; i < fromInteger(maxPkts); i <= i + 1)
            send(node(0, 0), node(x, y), truncate(pack(i)), i == fromInteger(maxPkts - 1));
         seq
            delay(fromInteger(stallCycles));
            collecting[x][y] <= True;
         endseq
      endpar
      drain;
   endseq;

   Stmt testStall = seq
      $display("[%0d] TEST 4: back-pressure from a destination that stops collecting", cycle);
      stallAt(cols - 1, rows - 1);   // far away: (3,3)
      stallAt(1, 0);                 // next door: the network between them fills up quickly
      $display("[%0d] TEST 4 passed", cycle);
   endseq;

   mkAutoFSM(seq
      testSingle;
      testAllPairs;
      testMessages;
      testStall;
      $display("[%0d] ALL TESTS PASSED", cycle);
   endseq);

endmodule

endpackage
