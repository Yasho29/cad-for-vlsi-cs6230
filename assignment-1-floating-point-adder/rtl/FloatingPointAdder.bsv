package FloatingPointAdder;

import FIFOF :: *;

typedef struct { Bool sign; Bit#(e) expo; Bit#(m) mant; }
   FP#(numeric type e, numeric type m) deriving (Bits, Eq, FShow);

typedef struct { Bool invalid; Bool overflow; Bool underflow; Bool inexact; }
   FPException deriving (Bits, Eq, FShow);

typedef struct { FP#(e,m) value; FPException flags; }
   FPResult#(numeric type e, numeric type m) deriving (Bits, Eq, FShow);

interface Ifc_floating_point_adder#(numeric type e, numeric type m);
   method Action ma_put_operands(FP#(e,m) op1, FP#(e,m) op2);
   method ActionValue#(FPResult#(e,m)) mav_get_result();
endinterface

typedef struct {
   Bool sign;
   Bool subtract;
   Bit#(e) expo;
   Bit#(TAdd#(m,1)) bigSig;
   Bit#(TAdd#(m,4)) alignedSig;
} Aligned#(numeric type e, numeric type m) deriving (Bits, Eq, FShow);

typedef struct {
   Bool sign;
   Bool subtract;
   UInt#(TAdd#(e,1)) expo;
   Bit#(TAdd#(m,4)) mag;
} RawSum#(numeric type e, numeric type m) deriving (Bits, Eq, FShow);

function Bit#(w) rshiftJam(Bit#(w) x, Bit#(e) n);
   Bit#(w) y = x >> n;
   if (x != (y << n)) y[0] = 1'b1;
   return y;
endfunction

function Bool isNaN(FP#(e,m) x);
   return x.expo == '1 && x.mant != 0;
endfunction

function Bool isInf(FP#(e,m) x);
   return x.expo == '1 && x.mant == 0;
endfunction

function Bool isZero(FP#(e,m) x);
   return x.expo == 0 && x.mant == 0;
endfunction

function Bool isSNaN(FP#(e,m) x);
   return isNaN(x) && x.mant[valueOf(m)-1] == 0;
endfunction

function Bool isSpecial(FP#(e,m) a, FP#(e,m) b);
   return isNaN(a) || isNaN(b) || isInf(a) || isInf(b) ||
          isZero(a) || isZero(b);
endfunction

function FPException cleanFlags();
   return FPException {
      invalid: False,
      overflow: False,
      underflow: False,
      inexact: False
   };
endfunction

function FP#(e,m) qNaN();
   FP#(e,m) x = FP { sign: False, expo: '1, mant: 0 };
   x.mant[valueOf(m)-1] = 1;
   return x;
endfunction

function FPResult#(e,m) specialResult(FP#(e,m) a, FP#(e,m) b);
   FPException f = cleanFlags;
   FP#(e,m) v = FP { sign: False, expo: 0, mant: 0 };

   if (isNaN(a) || isNaN(b)) begin
      v = qNaN;
      f.invalid = isSNaN(a) || isSNaN(b);
   end
   else if (isInf(a) && isInf(b) && a.sign != b.sign) begin
      v = qNaN;
      f.invalid = True;
   end
   else if (isInf(a)) v = a;
   else if (isInf(b)) v = b;
   else if (isZero(a) && isZero(b)) v.sign = a.sign && b.sign;
   else if (isZero(a)) v = b;
   else v = a;

   return FPResult { value: v, flags: f };
endfunction

module mkFloatingPointAdder(Ifc_floating_point_adder#(e,m))
   provisos (Add#(2,_e0,e), Add#(2,_m0,m));

   FIFOF#(Tuple2#(FP#(e,m),FP#(e,m))) inputQ <- mkFIFOF;
   FIFOF#(Tuple3#(Bool,FPResult#(e,m),Aligned#(e,m))) stage1Q <- mkFIFOF;
   FIFOF#(FPResult#(e,m)) outputQ <- mkFIFOF;

   Reg#(Tuple3#(Bool,FPResult#(e,m),RawSum#(e,m))) stage2Reg <- mkRegU;
   Reg#(Bool) stage2Valid <- mkReg(False);

   // STAGE 1: Compare + Align
   rule stage1(inputQ.notEmpty && stage1Q.notFull);
      let operands = inputQ.first;
      FP#(e,m) a = tpl_1(operands);
      FP#(e,m) b = tpl_2(operands);

      Bool special = isSpecial(a,b);
      FPResult#(e,m) specialValue = specialResult(a,b);

      Aligned#(e,m) aligned = Aligned {
         sign: False,
         subtract: False,
         expo: 0,
         bigSig: 0,
         alignedSig: 0
      };

      if (!special) begin
         Bit#(TAdd#(m,1)) sigA =
            (a.expo == 0) ? {1'b0,a.mant} : {1'b1,a.mant};

         Bit#(TAdd#(m,1)) sigB =
            (b.expo == 0) ? {1'b0,b.mant} : {1'b1,b.mant};

         Bit#(e) expA = (a.expo == 0) ? 1 : a.expo;
         Bit#(e) expB = (b.expo == 0) ? 1 : b.expo;

         Bool aIsBig =
            (expA > expB) ||
            ((expA == expB) && (sigA >= sigB));

         Bit#(TAdd#(m,1)) bigSig =
            aIsBig ? sigA : sigB;

         Bit#(TAdd#(m,1)) smallSig =
            aIsBig ? sigB : sigA;

         Bit#(e) resultExp =
            aIsBig ? expA : expB;

         Bit#(e) expGap =
            aIsBig ? expA-expB : expB-expA;

         Bool resultSign =
            aIsBig ? a.sign : b.sign;

         Bool smallSign =
            aIsBig ? b.sign : a.sign;

         aligned = Aligned {
            sign: resultSign,
            subtract: resultSign != smallSign,
            expo: resultExp,
            bigSig: bigSig,
            alignedSig: rshiftJam({smallSig,3'b000},expGap)
         };
      end

      stage1Q.enq(tuple3(special,specialValue,aligned));
      inputQ.deq;
   endrule

   // STAGE 2: Add/Subtract
   rule stage2(stage1Q.notEmpty && !stage2Valid);
      let stage = stage1Q.first;

      Bool special = tpl_1(stage);
      FPResult#(e,m) specialValue = tpl_2(stage);
      Aligned#(e,m) a = tpl_3(stage);

      RawSum#(e,m) raw = RawSum {
         sign: False,
         subtract: False,
         expo: 0,
         mag: 0
      };

      if (!special) begin
         Bit#(TAdd#(m,5)) sum =
            zeroExtend({a.bigSig,3'b000}) +
            zeroExtend(a.alignedSig);

         Bit#(TAdd#(m,4)) magnitude =
            a.subtract ?
            ({a.bigSig,3'b000} - a.alignedSig) :
            truncate(sum);

         UInt#(TAdd#(e,1)) resultExp =
            unpack(zeroExtend(a.expo));

         if (!a.subtract &&
             sum[valueOf(TAdd#(m,5))-1] == 1) begin

            Bit#(e) one = 1;

            magnitude = truncate(rshiftJam(sum,one));
            resultExp = resultExp + 1;
         end

         raw = RawSum {
            sign: a.sign,
            subtract: a.subtract,
            expo: resultExp,
            mag: magnitude
         };
      end

      stage2Reg <= tuple3(special,specialValue,raw);
      stage2Valid <= True;
      stage1Q.deq;
   endrule

   // STAGE 3: Normalize + Round + Pack.  Normalization iterates only after
   // cancellation, so this stage has a short, compiler-friendly critical path.
   rule normalizeStep(stage2Valid && !tpl_1(stage2Reg) &&
                      tpl_3(stage2Reg).subtract &&
                      tpl_3(stage2Reg).mag != 0 &&
                      tpl_3(stage2Reg).mag[valueOf(TAdd#(m,4))-1] == 0 &&
                      tpl_3(stage2Reg).expo > 1);
      Bool special = tpl_1(stage2Reg);
      FPResult#(e,m) specialValue = tpl_2(stage2Reg);
      RawSum#(e,m) raw = tpl_3(stage2Reg);
      raw.mag = raw.mag << 1;
      raw.expo = raw.expo - 1;
      stage2Reg <= tuple3(special,specialValue,raw);
   endrule

   rule stage3(stage2Valid && outputQ.notFull &&
               (tpl_1(stage2Reg) || !tpl_3(stage2Reg).subtract ||
                tpl_3(stage2Reg).mag == 0 ||
                tpl_3(stage2Reg).mag[valueOf(TAdd#(m,4))-1] == 1 ||
                tpl_3(stage2Reg).expo == 1));

      let stage = stage2Reg;

      Bool special = tpl_1(stage);
      FPResult#(e,m) result = tpl_2(stage);
      RawSum#(e,m) raw = tpl_3(stage);

      if (!special) begin

         Bit#(TAdd#(m,4)) magnitude = raw.mag;
         UInt#(TAdd#(e,1)) resultExp = raw.expo;

         FP#(e,m) value = FP {
            sign: raw.sign,
            expo: 0,
            mant: 0
         };

         FPException flags = cleanFlags;

         if (magnitude == 0) begin
            value.sign = False;
         end
         else begin

            Bit#(TAdd#(m,1)) kept =
               truncate(magnitude >> 3);

            Bool discarded =
               magnitude[2] == 1 ||
               magnitude[1] == 1 ||
               magnitude[0] == 1;

            Bool roundUp =
               magnitude[2] == 1 &&
               (magnitude[1] == 1 ||
                magnitude[0] == 1 ||
                kept[0] == 1);

            Bit#(TAdd#(m,2)) rounded =
               zeroExtend(kept) +
               (roundUp ? 1 : 0);

            if (rounded[valueOf(TAdd#(m,2))-1] == 1) begin
               kept = truncate(rounded >> 1);
               resultExp = resultExp + 1;
            end
            else begin
               kept = truncate(rounded);
            end

            Bit#(e) maxExpo = '1;

            if (resultExp >= unpack(zeroExtend(maxExpo))) begin
               value.expo = '1;
               value.mant = 0;
               flags.overflow = True;
               flags.inexact = True;
            end
            else begin
               value.expo =
                  kept[valueOf(m)] == 1 ?
                  truncate(pack(resultExp)) :
                  0;

               value.mant = truncate(kept);
               flags.inexact = discarded;
               flags.underflow =
                  value.expo == 0 && discarded;
            end
         end

         result = FPResult {
            value: value,
            flags: flags
         };
      end

      outputQ.enq(result);
      stage2Valid <= False;
   endrule

   method Action ma_put_operands(
      FP#(e,m) op1,
      FP#(e,m) op2
   ) if (inputQ.notFull);

      inputQ.enq(tuple2(op1,op2));
   endmethod

   method ActionValue#(FPResult#(e,m)) mav_get_result()
      if (outputQ.notEmpty);

      let r = outputQ.first;
      outputQ.deq;
      return r;
   endmethod

endmodule

endpackage : FloatingPointAdder
