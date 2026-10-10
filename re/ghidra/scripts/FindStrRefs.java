// Find occurrences of a NUL-terminated string in the program, then list every
// existing code reference to each occurrence.
// Args: <string> [string ...]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.util.*;

public class FindStrRefs extends GhidraScript {
    byte[] needle;
    List<Address> hits = new ArrayList<>();

    void find() throws Exception {
        Memory mem = currentProgram.getMemory();
        byte[] data = new byte[3 * 1024 * 1024];
        for (MemoryBlock b : mem.getBlocks()) {
            Address s = b.getStart();
            long sz = b.getSize();
            if (sz > data.length) continue;
            mem.getBytes(s, data);
            Address base = s;
            outer:
            for (int i = 0; i + needle.length <= sz; i++) {
                for (int j = 0; j < needle.length; j++)
                    if (data[i + j] != needle[j]) continue outer;
                hits.add(base.add(i));
                i += needle.length - 1;
            }
        }
        Collections.sort(hits);
    }

    // Fallback: scan code blocks for the 4-byte absolute address (big-endian)
    // exactly as ColdFire lea/movel would encode it.
    void rawScan(Address h) throws Exception {
        Memory mem = currentProgram.getMemory();
        byte[] a = new byte[4];
        a[0] = (byte) (h >> 24); a[1] = (byte) (h >> 16); a[2] = (byte) (h >> 8); a[3] = (byte) h;
        for (MemoryBlock b : mem.getBlocks()) {
            long sz = b.getSize();
            if (sz < 4 || sz > 4 * 1024 * 1024) continue;
            byte[] data = new byte[(int) sz];
            mem.getBytes(b.getStart(), data);
            for (int i = 0; i + 4 <= sz; i++) {
                if (data[i] == a[0] && data[i + 1] == a[1] && data[i + 2] == a[2] && data[i + 3] == a[3]) {
                    Address r = b.getStart().add(i);
                    Function f = getFunctionContaining(r);
                    println("   raw ea at " + r + (f == null ? "" : "  in " + f.getName() + " @ " + f.getEntryPoint()));
                }
            }
        }
    }

    @Override
    public void run() throws Exception {
        for (String s : getScriptArgs()) {
            needle = s.getBytes("US-ASCII");
            hits.clear();
            find();
            if (hits.isEmpty()) { println(s + ": not found"); continue; }
            for (Address h : hits) {
                println("=== \"" + s + "\" at " + h);
                ReferenceIterator it = currentProgram.getReferenceManager().getReferencesTo(h);
                int c = 0;
                while (it.hasNext() && c < 40) {
                    Reference r = it.next();
                    Function f = getFunctionContaining(r.getFromAddress());
                    println("   ref from " + r.getFromAddress() + (f == null ? "" : "  in " + f.getName() + " @ " + f.getEntryPoint()));
                    c++;
                }
                if (c == 0) println("   (no references recorded)");
                if (c < 3) rawScan(h);
            }
        }
    }
}
