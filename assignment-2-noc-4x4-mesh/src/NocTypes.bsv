package NocTypes;

import Vector :: *;

typedef 4   MeshCols;        // routers along x, left to right
typedef 4   MeshRows;        // routers along y, top to bottom
typedef 2   CoordWidth;      // bits per coordinate
typedef 3   SeqWidth;        // bits of sequence number
typedef 32  PayloadBytes;    // payload carried by one packet
typedef TMul#(PayloadBytes, 8) PayloadWidth;

typedef struct {
   Bit#(CoordWidth) x;
   Bit#(CoordWidth) y;
} NodeAddr deriving (Bits, Eq, FShow);

typedef struct {
   NodeAddr             src;
   NodeAddr             dst;
   Bool                 is_last;
   Bit#(SeqWidth)       seq_num;
   Bit#(PayloadWidth)   payload;
} NocPacket deriving (Bits, Eq, FShow);

// The port through which a PE talks to its router.
interface Ifc_noc_port;
   method Action ma_put_packet (NocPacket pkt);
   method ActionValue#(NocPacket) mav_get_packet ();
endinterface

// The whole network: node[x][y] is the local port of the router at (x, y).
interface Ifc_noc;
   interface Vector#(MeshCols, Vector#(MeshRows, Ifc_noc_port)) node;
endinterface

endpackage
