import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;

public class FuncInfo extends GhidraScript {
    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        println("TOTAL FUNCTIONS: " + fm.getFunctionCount());
        for (String a : getScriptArgs()) {
            Address addr = currentProgram.getAddressFactory().getAddress(a);
            Function c = fm.getFunctionContaining(addr);
            println(a + " containing=" + (c == null ? "none" : c.getName() + "@" + c.getEntryPoint() + " body=" + c.getBody()));
            Function b = getFunctionBefore(addr);
            println("   before=" + (b == null ? "none" : b.getName() + "@" + b.getEntryPoint() + " end=" + b.getBody().getMaxAddress()));
            Function n = getFunctionAfter(addr);
            println("   after =" + (n == null ? "none" : n.getName() + "@" + n.getEntryPoint()));
        }
    }
}
