// Decompile the function containing each address given as a script argument.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class DecompAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);
        for (String a : getScriptArgs()) {
            Address addr = currentProgram.getAddressFactory().getAddress(a);
            Function f = getFunctionContaining(addr);
            if (f == null) {
                println("=== " + a + ": no function; creating");
                f = createFunction(addr, null);
                if (f == null) { println("=== " + a + ": FAILED"); continue; }
            }
            println("=== " + f.getName() + " @ " + f.getEntryPoint() + " (asked " + a + ") ===");
            DecompileResults r = d.decompileFunction(f, 120, monitor);
            if (r.decompileCompleted()) println(r.getDecompiledFunction().getC());
            else println("DECOMPILE FAILED: " + r.getErrorMessage());
        }
    }
}
