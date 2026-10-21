package Noc;

import Vector    :: *;
import NocTypes  :: *;
import NocRouter :: *;

(* synthesize *)
module mkNoc (Ifc_noc);

   // Instantiate one router from NocRouter package for every (x, y)
   Vector#(MeshCols, Vector#(MeshRows, Ifc_noc_router)) routers = newVector;

   for (Integer x = 0; x < valueOf(MeshCols); x = x + 1) begin
      for (Integer y = 0; y < valueOf(MeshRows); y = y + 1) begin
         NodeAddr addr = NodeAddr { x: fromInteger(x), y: fromInteger(y) };
         routers[x][y] <- mkNocRouter(addr);
      end
   end

   // Connect routers along horizontal links (X direction):
   // Between (x, y) and (x+1, y)
   for (Integer x = 0; x < valueOf(MeshCols) - 1; x = x + 1) begin
      for (Integer y = 0; y < valueOf(MeshRows); y = y + 1) begin
         // Traffic going East: from (x, y) East output to (x+1, y) West input
         rule link_east;
            let p <- routers[x][y].east.mav_get_packet;
            routers[x+1][y].west.ma_put_packet(p);
         endrule

         // Traffic going West: from (x+1, y) West output to (x, y) East input
         rule link_west;
            let p <- routers[x+1][y].west.mav_get_packet;
            routers[x][y].east.ma_put_packet(p);
         endrule
      end
   end

   // Connect routers along vertical links (Y direction):
   // Between (x, y) and (x, y+1)
   for (Integer x = 0; x < valueOf(MeshCols); x = x + 1) begin
      for (Integer y = 0; y < valueOf(MeshRows) - 1; y = y + 1) begin
         // Traffic going South: from (x, y) South output to (x, y+1) North input
         rule link_south;
            let p <- routers[x][y].south.mav_get_packet;
            routers[x][y+1].north.ma_put_packet(p);
         endrule

         // Traffic going North: from (x, y+1) North output to (x, y) South input
         rule link_north;
            let p <- routers[x][y+1].north.mav_get_packet;
            routers[x][y].south.ma_put_packet(p);
         endrule
      end
   end

   // Expose each router's local port as node[x][y]
   Vector#(MeshCols, Vector#(MeshRows, Ifc_noc_port)) local_nodes = newVector;
   for (Integer x = 0; x < valueOf(MeshCols); x = x + 1) begin
      for (Integer y = 0; y < valueOf(MeshRows); y = y + 1) begin
         local_nodes[x][y] = routers[x][y].local_port;
      end
   end

   interface node = local_nodes;

endmodule

endpackage
