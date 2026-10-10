// args: <entry_hex> ... ; disassemble + create function + decompile
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;

public class ForceFunc extends GhidraScript {
    @Override
    public void run() throws Exception {
        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);
        FunctionManager fm = currentProgram.getFunctionManager();
        for (String a : getScriptArgs()) {
            Address addr = currentProgram.getAddressFactory().getAddress(a);
            Function f = fm.getFunctionContaining(addr);
            if (f != null && !f.getEntryPoint().equals(addr)) { removeFunction(f); f = null; }
            if (f != null && f.getBody().getNumAddresses() < 8) { removeFunction(f); f = null; }
            disassemble(addr);
            if (f == null) f = createFunction(addr, null);
            if (f == null) { println("=== " + a + " FAILED to create"); continue; }
            println("=== " + f.getName() + " @ " + f.getEntryPoint() + " size=" + f.getBody().getNumAddresses());
            DecompileResults r = d.decompileFunction(f, 300, monitor);
            if (r.decompileCompleted()) println(r.getDecompiledFunction().getC());
            else println("DECOMPILE FAILED: " + r.getErrorMessage());
        }
    }
}
