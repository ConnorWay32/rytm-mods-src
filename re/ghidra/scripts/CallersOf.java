// Accurate reverse call graph for the addresses given as script arguments.
// Uses Ghidra's function model and reference index rather than nearest-entry
// heuristics, which misattribute call sites badly in this image.
// Args: <addr> [addr ...] [--depth N] [--max M]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.*;
import java.util.*;

public class CallersOf extends GhidraScript {
    int depth = 3, max = 40;

    Set<Function> callersOf(Function f) {
        Set<Function> out = new LinkedHashSet<>();
        ReferenceIterator it = currentProgram.getReferenceManager()
                .getReferencesTo(f.getEntryPoint());
        while (it.hasNext()) {
            Reference r = it.next();
            if (!r.getReferenceType().isCall() && !r.getReferenceType().isJump()) continue;
            Function c = getFunctionContaining(r.getFromAddress());
            if (c != null && !c.equals(f)) out.add(c);
        }
        return out;
    }

    void walk(Function f, int d, Set<Function> seen, String pad) {
        if (d > depth) return;
        Set<Function> cs = callersOf(f);
        if (cs.isEmpty()) { println(pad + "  <no callers - root or table-dispatched>"); return; }
        if (cs.size() > max) {
            println(pad + "  <" + cs.size() + " callers - generic utility, not walked>");
            return;
        }
        for (Function c : cs) {
            println(pad + "  " + c.getName() + " @ " + c.getEntryPoint());
            if (seen.add(c)) walk(c, d + 1, seen, pad + "  ");
        }
    }

    @Override
    public void run() throws Exception {
        List<String> addrs = new ArrayList<>();
        String[] a = getScriptArgs();
        for (int i = 0; i < a.length; i++) {
            if (a[i].equals("--depth")) depth = Integer.parseInt(a[++i]);
            else if (a[i].equals("--max")) max = Integer.parseInt(a[++i]);
            else addrs.add(a[i]);
        }
        for (String s : addrs) {
            Address ad = currentProgram.getAddressFactory().getAddress(s);
            Function f = getFunctionContaining(ad);
            if (f == null) { println("=== " + s + ": no function"); continue; }
            println("===== " + f.getName() + " @ " + f.getEntryPoint() + " (asked " + s + ")");
            walk(f, 1, new HashSet<>(), "");
        }
    }
}
