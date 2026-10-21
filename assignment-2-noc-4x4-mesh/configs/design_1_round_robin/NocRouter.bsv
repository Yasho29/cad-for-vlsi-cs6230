package NocRouter;

import Vector       :: *;
import FIFOF        :: *;
import SpecialFIFOs :: *;
import NocTypes     :: *;

Integer inDepth  = 2;
Integer outDepth  = 2;

// Port indices / directions
typedef enum {
   DirNorth = 0,
   DirEast  = 1,
   DirSouth = 2,
   DirWest  = 3,
   DirLocal = 4
} Direction deriving (Bits, Eq, FShow);

typedef 5 NumPorts;

Integer portNorth = 0;
Integer portEast  = 1;
Integer portSouth = 2;
Integer portWest  = 3;
Integer portLocal = 4;

interface Ifc_noc_router;
   interface Ifc_noc_port north;
   interface Ifc_noc_port east;
   interface Ifc_noc_port south;
   interface Ifc_noc_port west;
   interface Ifc_noc_port local_port;
endinterface

// Dimension-order (X-Y) routing function
function Direction route (NodeAddr my_addr, NodeAddr dst);
   if (dst.x > my_addr.x)
      return DirEast;
   else if (dst.x < my_addr.x)
      return DirWest;
   else if (dst.y > my_addr.y)
      return DirSouth;
   else if (dst.y < my_addr.y)
      return DirNorth;
   else
      return DirLocal;
endfunction

// Round-Robin arbiter selection
function Maybe#(UInt#(3)) select_winner (
   UInt#(3) prio,
   Vector#(NumPorts, Bool) req
);
   Maybe#(UInt#(3)) res = tagged Invalid;
   for (Integer step = valueOf(NumPorts) - 1; step >= 0; step = step - 1) begin
      UInt#(4) sum = zeroExtend(prio) + fromInteger(step);
      UInt#(3) cand = truncate(sum >= fromInteger(valueOf(NumPorts)) ? 
                               (sum - fromInteger(valueOf(NumPorts))) : sum);
      if (req[cand])
         res = tagged Valid cand;
   end
   return res;
endfunction

module mkNocRouter #(NodeAddr my_addr) (Ifc_noc_router);

   Vector#(NumPorts, FIFOF#(NocPacket)) in_q  <- replicateM(mkUGSizedFIFOF(inDepth));
   Vector#(NumPorts, FIFOF#(NocPacket)) out_q <- replicateM(mkUGSizedFIFOF(outDepth));
   Vector#(NumPorts, Reg#(UInt#(3))) rr_prio  <- replicateM(mkReg(0));

   rule do_crossbar;
      // 1. Gather status and destination from all input ports
      Vector#(NumPorts, Bool) in_valid = newVector;
      Vector#(NumPorts, Direction) in_req = newVector;
      Vector#(NumPorts, NocPacket) in_data = newVector;

      for (Integer i = 0; i < valueOf(NumPorts); i = i + 1) begin
         in_valid[i] = in_q[i].notEmpty;
         in_req[i]   = in_q[i].notEmpty ? route(my_addr, in_q[i].first.dst) : DirLocal;
         in_data[i]  = in_q[i].first;
      end

      // 2. Arbitrate per output port
      Vector#(NumPorts, Maybe#(UInt#(3))) win_input = replicate(tagged Invalid);

      for (Integer j = 0; j < valueOf(NumPorts); j = j + 1) begin
         if (out_q[j].notFull) begin
            Vector#(NumPorts, Bool) req_to_j = newVector;
            for (Integer i = 0; i < valueOf(NumPorts); i = i + 1) begin
               req_to_j[i] = in_valid[i] && (pack(in_req[i]) == fromInteger(j));
            end
            let win = select_winner(rr_prio[j], req_to_j);
            if (win matches tagged Valid .cand) begin
               win_input[j] = tagged Valid cand;
               rr_prio[j] <= (cand == fromInteger(valueOf(NumPorts) - 1)) ? 0 : (cand + 1);
            end
         end
      end

      // 3. Move packets to outputs
      for (Integer j = 0; j < valueOf(NumPorts); j = j + 1) begin
         if (win_input[j] matches tagged Valid .cand) begin
            out_q[j].enq(in_data[cand]);
         end
      end

      // 4. Dequeue winning inputs
      Vector#(NumPorts, Bool) in_granted = replicate(False);
      for (Integer j = 0; j < valueOf(NumPorts); j = j + 1) begin
         if (win_input[j] matches tagged Valid .cand) begin
            for (Integer i = 0; i < valueOf(NumPorts); i = i + 1) begin
               if (fromInteger(i) == cand) in_granted[i] = True;
            end
         end
      end

      for (Integer i = 0; i < valueOf(NumPorts); i = i + 1) begin
         if (in_granted[i]) begin
            in_q[i].deq;
         end
      end
   endrule

   // Port sub-interfaces
   function Ifc_noc_port makePort(Integer idx) =
      interface Ifc_noc_port;
         method Action ma_put_packet (NocPacket pkt) if (in_q[idx].notFull);
            in_q[idx].enq(pkt);
         endmethod
         method ActionValue#(NocPacket) mav_get_packet () if (out_q[idx].notEmpty);
            let p = out_q[idx].first;
            out_q[idx].deq;
            return p;
         endmethod
      endinterface;

   interface north      = makePort(portNorth);
   interface east       = makePort(portEast);
   interface south      = makePort(portSouth);
   interface west       = makePort(portWest);
   interface local_port = makePort(portLocal);

endmodule

endpackage
