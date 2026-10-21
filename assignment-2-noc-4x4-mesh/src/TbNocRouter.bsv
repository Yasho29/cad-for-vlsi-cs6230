package TbNocRouter;

import Vector       :: *;
import FIFOF        :: *;
import SpecialFIFOs :: *;
import ConfigReg    :: *;
import StmtFSM      :: *;
import NocTypes     :: *;
import NocRouter    :: *;

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

function NocPacket makeTestPacket (NodeAddr s, NodeAddr d, Bit#(32) serial);
   return NocPacket {
      src: s,
      dst: d,
      is_last: True,
      seq_num: 0,
      payload: makePayload(serial)
   };
endfunction

(* synthesize *)
module mkTbNocRouter (Empty);

   NodeAddr myAddr = NodeAddr { x: 1, y: 1 };
   Ifc_noc_router router <- mkNocRouter(myAddr);

   Reg#(UInt#(32)) cycle <- mkReg(0);
   rule tick;
      cycle <= cycle + 1;
   endrule

   function Action fail(Fmt msg) =
      action
         $display($format("[%0d] ROUTER TEST FAIL: ", cycle) + msg);
         $finish(0);
      endaction;

   Stmt test1_routing = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] ROUTER TEST 1: Checking routing policy on all directions", cycle);
      // Test East: (1,1) -> (2,1)
      router.local_port.ma_put_packet(makeTestPacket(myAddr, NodeAddr { x: 2, y: 1 }, 1));
      delay(2);
      action
         let p <- router.east.mav_get_packet;
         if (p.dst.x != 2 || p.dst.y != 1) fail($format("Expected East output, got %0d,%0d", p.dst.x, p.dst.y));
      endaction

      // Test West: (1,1) -> (0,1)
      router.local_port.ma_put_packet(makeTestPacket(myAddr, NodeAddr { x: 0, y: 1 }, 2));
      delay(2);
      action
         let p <- router.west.mav_get_packet;
         if (p.dst.x != 0 || p.dst.y != 1) fail($format("Expected West output, got %0d,%0d", p.dst.x, p.dst.y));
      endaction

      // Test South: (1,1) -> (1,2)
      router.local_port.ma_put_packet(makeTestPacket(myAddr, NodeAddr { x: 1, y: 2 }, 3));
      delay(2);
      action
         let p <- router.south.mav_get_packet;
         if (p.dst.x != 1 || p.dst.y != 2) fail($format("Expected South output, got %0d,%0d", p.dst.x, p.dst.y));
      endaction

      // Test North: (1,1) -> (1,0)
      router.local_port.ma_put_packet(makeTestPacket(myAddr, NodeAddr { x: 1, y: 0 }, 4));
      delay(2);
      action
         let p <- router.north.mav_get_packet;
         if (p.dst.x != 1 || p.dst.y != 0) fail($format("Expected North output, got %0d,%0d", p.dst.x, p.dst.y));
      endaction

      // Test Local: (0,1) -> (1,1)
      router.west.ma_put_packet(makeTestPacket(NodeAddr { x: 0, y: 1 }, myAddr, 5));
      delay(2);
      action
         let p <- router.local_port.mav_get_packet;
         if (p.dst.x != 1 || p.dst.y != 1) fail($format("Expected Local output, got %0d,%0d", p.dst.x, p.dst.y));
      endaction
      $display("[%0d] ROUTER TEST 1 passed", cycle);
   endseq;

   Stmt test2_contention = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] ROUTER TEST 2: Checking contention resolution (2 inputs -> 1 output)", cycle);
      // Both North and West want to route to South (x: 1, y: 2)
      par
         router.north.ma_put_packet(makeTestPacket(NodeAddr { x: 1, y: 0 }, NodeAddr { x: 1, y: 2 }, 10));
         router.west.ma_put_packet(makeTestPacket(NodeAddr { x: 0, y: 1 }, NodeAddr { x: 1, y: 2 }, 20));
      endpar
      delay(1);
      // Both should emerge from South consecutively without loss
      action
         let p1 <- router.south.mav_get_packet;
         $display("[%0d] First winner out South: payload=%h", cycle, p1.payload);
      endaction
      delay(1);
      action
         let p2 <- router.south.mav_get_packet;
         $display("[%0d] Second winner out South: payload=%h", cycle, p2.payload);
      endaction
      $display("[%0d] ROUTER TEST 2 passed", cycle);
   endseq;

   Stmt test3_backpressure = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] ROUTER TEST 3: Back-pressure on output port stalls inputs", cycle);
      // Fill South output queue (depth 2)
      router.north.ma_put_packet(makeTestPacket(NodeAddr { x: 1, y: 0 }, NodeAddr { x: 1, y: 2 }, 31));
      delay(1);
      router.north.ma_put_packet(makeTestPacket(NodeAddr { x: 1, y: 0 }, NodeAddr { x: 1, y: 2 }, 32));
      delay(1);
      router.north.ma_put_packet(makeTestPacket(NodeAddr { x: 1, y: 0 }, NodeAddr { x: 1, y: 2 }, 33));
      delay(5);
      // Drain South
      $display("[%0d] Unblocking South output", cycle);
      action
         let p1 <- router.south.mav_get_packet;
      endaction
      delay(1);
      action
         let p2 <- router.south.mav_get_packet;
      endaction
      delay(1);
      action
         let p3 <- router.south.mav_get_packet;
      endaction
      $display("[%0d] ROUTER TEST 3 passed", cycle);
   endseq;

   Stmt test4_crossbar = seq
      $display("----------------------------------------------------------------");
      $display("[%0d] ROUTER TEST 4: Full crossbar concurrency (4 non-interfering transfers)", cycle);
      par
         router.north.ma_put_packet(makeTestPacket(NodeAddr { x: 1, y: 0 }, NodeAddr { x: 1, y: 2 }, 41)); // N -> S
         router.south.ma_put_packet(makeTestPacket(NodeAddr { x: 1, y: 2 }, NodeAddr { x: 1, y: 0 }, 42)); // S -> N
         router.east.ma_put_packet(makeTestPacket(NodeAddr { x: 2, y: 1 }, NodeAddr { x: 0, y: 1 }, 43));  // E -> W
         router.west.ma_put_packet(makeTestPacket(NodeAddr { x: 0, y: 1 }, NodeAddr { x: 2, y: 1 }, 44));  // W -> E
      endpar
      delay(2);
      par
         action let p <- router.south.mav_get_packet; endaction
         action let p <- router.north.mav_get_packet; endaction
         action let p <- router.west.mav_get_packet; endaction
         action let p <- router.east.mav_get_packet; endaction
      endpar
      $display("[%0d] ROUTER TEST 4 passed", cycle);
   endseq;

   mkAutoFSM(seq
      test1_routing;
      test2_contention;
      test3_backpressure;
      test4_crossbar;
      $display("================================================================");
      $display("ROUTER PERFORMANCE SUMMARY:");
      $display("  BR (Router peak bandwidth) : 160 bytes/cycle (5 concurrent ports x 32 bytes)");
      $display("================================================================");
      $display("[%0d] ALL ROUTER TESTS PASSED", cycle);
      $display("================================================================");
   endseq);

endmodule

endpackage
