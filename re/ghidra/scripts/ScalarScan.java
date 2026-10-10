// Every instruction whose operands contain a given scalar, with its function.
//
// Struct fields in this image are reached through several addressing modes -
// (d16,An), (d8,An,Xn), and a `lea` that folds the displacement away - so a byte
// scan for one encoding misses most uses. Ghidra has already decoded the operands,
// so ask it instead.
//
// Args: <value> [value ...] [--max N]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.scalar.Scalar;
import java.util.*;

public class ScalarScan extends GhidraScript {
    @Override
    public void run() throws Exception {
        Set<Long> want = new LinkedHashSet<>();
        int max = 400;
        String[] args = getScriptArgs();
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--max")) { max = Integer.parseInt(args[++i]); continue; }
            want.add(Long.decode(args[i]));
        }
        if (want.isEmpty()) { println("usage: ScalarScan <value> [value ...] [--max N]"); return; }

        int hits = 0;
        InstructionIterator it = currentProgram.getListing().getInstructions(true);
        while (it.hasNext() && hits < max) {
            if (monitor.isCancelled()) break;
            Instruction ins = it.next();
            boolean match = false;
            for (int op = 0; op < ins.getNumOperands() && !match; op++) {
                for (Object o : ins.getOpObjects(op)) {
                    if (o instanceof Scalar && want.contains(((Scalar) o).getUnsignedValue())) {
                        match = true;
                        break;
                    }
                }
            }
            if (!match) continue;
            hits++;
            Address a = ins.getAddress();
            Function f = getFunctionContaining(a);
            println(String.format("%s  %-40s  %s", a, ins.toString(),
                    f == null ? "<no function>" : f.getName() + "+" +
                        (a.getOffset() - f.getEntryPoint().getOffset())));
        }
        println("---- " + hits + " hit(s)" + (hits >= max ? " (truncated)" : ""));
    }
}
