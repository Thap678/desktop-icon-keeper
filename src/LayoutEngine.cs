// 桌面图标保镖 —— 相对布局引擎（纯算法，不碰 Win32，可单独测试）
//
// 思路：把图标看成网格上的格子 (列, 行)，换屏幕时不按像素等比缩放，而是：
//   1. 弹性间隙映射（ElasticMap）：分别沿 X / Y 轴，把“被占用的列/行”之间的空白当作弹簧。
//      屏幕变小 → 先压缩最大的空白（通常是屏幕另一侧的大片空地），组内/组间的小间距尽量保留；
//      屏幕变大 → 只拉伸“大空白”，于是贴左的留在左边、贴右的留在右边、居中的保持居中。
//   2. 溢出处理：某一簇图标比新屏幕还高时，放得下的原地不动，只把底部溢出的几个挪走——
//      先填进这一簇自己范围内的空洞（自动靠拢），还不够就在它右侧追加新列，
//      并在全局插入相应的列，把右边的东西整体往右推。
//   3. 推挤（DikPlacer）：按簇整体落位，落点被占就整簇平移到最近的空位；
//      整簇放不下才拆成单个图标，各自找最近的空格。
// 需要能被 Windows PowerShell 5.1 自带的 C# 5 编译器编译。
using System;
using System.Collections.Generic;

public static class DikLayout {

    // ------------------------------------------------------------------
    // 1D 弹性映射
    // used: 升序、去重的已占用坐标；srcN: 原来的格数；dstN: 新的格数。
    // 返回每个 used 坐标映射后的新坐标（单调递增；若占用数 > dstN 则会超出 dstN-1，由调用方处理）。
    // ------------------------------------------------------------------
    public static int[] ElasticMap(int[] used, int srcN, int dstN) {
        int m = used.Length;
        int[] res = new int[m];
        if (m == 0) return res;
        if (srcN < used[m - 1] + 1) srcN = used[m - 1] + 1;

        int[] gap = new int[m + 1];
        gap[0] = Math.Max(0, used[0]);
        for (int i = 1; i < m; i++) gap[i] = used[i] - used[i - 1] - 1;
        gap[m] = srcN - 1 - used[m - 1];

        int delta = dstN - srcN;
        if (delta < 0) Shrink(gap, -delta);
        else if (delta > 0) Grow(gap, delta);

        int pos = gap[0];
        res[0] = pos;
        for (int i = 1; i < m; i++) { pos += 1 + gap[i]; res[i] = pos; }
        return res;
    }

    // 压缩：每次从当前最大的空白里拿走一格（“降水位”）。
    // 第一阶段组间空白至少留 1 格，不够再压到 0。平局时优先边缘（先尾后头），再优先右侧的组间空白。
    static void Shrink(int[] gap, int need) {
        int m = gap.Length - 1;
        for (int phase = 0; phase < 2 && need > 0; phase++) {
            int innerFloor = (phase == 0) ? 1 : 0;
            while (need > 0) {
                int best = -1;
                for (int k = 0; k <= m; k++) {
                    int floor = (k == 0 || k == m) ? 0 : innerFloor;
                    if (gap[k] <= floor) continue;
                    if (best < 0 || gap[k] > gap[best] || (gap[k] == gap[best] && Priority(k, m) > Priority(best, m))) best = k;
                }
                if (best < 0) break;
                gap[best]--;
                need--;
            }
        }
    }

    static int Priority(int k, int m) {
        if (k == m) return 1000000;
        if (k == 0) return 999999;
        return k;
    }

    // 拉伸：只让“大空白”（≥ 最大空白的一半）参与，按大小比例分配（最大余数法）。
    // 全部空白都是 0（图标铺满）时，多出来的全给尾部，相当于靠左/靠上。
    static void Grow(int[] gap, int extra) {
        int m = gap.Length - 1;
        int maxGap = 0;
        for (int k = 0; k <= m; k++) if (gap[k] > maxGap) maxGap = gap[k];
        if (maxGap == 0) { gap[m] += extra; return; }

        int threshold = Math.Max(1, (maxGap + 1) / 2);
        List<int> part = new List<int>();
        long total = 0;
        for (int k = 0; k <= m; k++) if (gap[k] >= threshold) { part.Add(k); total += gap[k]; }

        int given = 0;
        double[] rem = new double[part.Count];
        for (int i = 0; i < part.Count; i++) {
            double share = (double)extra * gap[part[i]] / total;
            int whole = (int)Math.Floor(share);
            rem[i] = share - whole;
            gap[part[i]] += whole;
            given += whole;
        }
        while (given < extra) {
            int bi = 0;
            for (int i = 1; i < part.Count; i++) {
                if (rem[i] > rem[bi] + 1e-9 || (Math.Abs(rem[i] - rem[bi]) <= 1e-9 && Priority(part[i], m) > Priority(part[bi], m))) bi = i;
            }
            gap[part[bi]]++;
            rem[bi] = -1;
            given++;
        }
    }

    // ------------------------------------------------------------------
    // 8 邻接连通的“簇”。返回每个图标所属簇编号（0..k-1）。
    // ------------------------------------------------------------------
    public static int[] Clusters(int[] cols, int[] rows) {
        int n = cols.Length;
        int[] id = new int[n];
        for (int i = 0; i < n; i++) id[i] = -1;
        Dictionary<long, List<int>> at = new Dictionary<long, List<int>>();
        for (int i = 0; i < n; i++) {
            long key = Key(cols[i], rows[i]);
            List<int> l;
            if (!at.TryGetValue(key, out l)) { l = new List<int>(); at[key] = l; }
            l.Add(i);
        }
        int next = 0;
        Queue<int> q = new Queue<int>();
        for (int s = 0; s < n; s++) {
            if (id[s] >= 0) continue;
            id[s] = next;
            q.Enqueue(s);
            while (q.Count > 0) {
                int i = q.Dequeue();
                for (int dx = -1; dx <= 1; dx++) {
                    for (int dy = -1; dy <= 1; dy++) {
                        List<int> l;
                        if (!at.TryGetValue(Key(cols[i] + dx, rows[i] + dy), out l)) continue;
                        foreach (int j in l) {
                            if (id[j] >= 0) continue;
                            id[j] = next;
                            q.Enqueue(j);
                        }
                    }
                }
            }
            next++;
        }
        return id;
    }

    static long Key(int c, int r) { return ((long)c << 32) ^ (uint)r; }

    // ------------------------------------------------------------------
    // 把一组图标从 srcC×srcR 的网格映射到 dstC×dstR 的网格（理想位置，可能仍有冲突/越界）。
    // outCluster 返回源布局中的簇编号，供 DikPlacer 整簇推挤用。
    // ------------------------------------------------------------------
    public static void MapGrid(int[] cols, int[] rows, int srcC, int srcR, int dstC, int dstR,
                               int[] outC, int[] outR, int[] outCluster) {
        int n = cols.Length;
        if (n == 0) return;
        if (dstC < 1) dstC = 1;
        if (dstR < 1) dstR = 1;

        int[] cid = Clusters(cols, rows);
        int clusterCount = 0;
        for (int i = 0; i < n; i++) if (cid[i] + 1 > clusterCount) clusterCount = cid[i] + 1;
        List<int>[] members = new List<int>[clusterCount];
        for (int k = 0; k < clusterCount; k++) members[k] = new List<int>();
        for (int i = 0; i < n; i++) members[cid[i]].Add(i);

        // ---- Y 轴 ----
        int[] yNew = MapAxis(rows, srcR, dstR);

        int[] effCol = new int[n];          // 源列坐标（溢出的图标可能被挪进簇内空洞）
        int[] appendOff = new int[n];       // >=0：追加在簇右侧的第几列
        int[] appendAfter = new int[n];
        for (int i = 0; i < n; i++) { effCol[i] = cols[i]; appendOff[i] = -1; }
        List<int> insAfter = new List<int>();
        List<int> insCount = new List<int>();

        for (int k = 0; k < clusterCount; k++) {
            List<int> mem = members[k];
            int top = int.MaxValue, bot = int.MinValue, cMin = int.MaxValue, cMax = int.MinValue;
            foreach (int i in mem) {
                if (yNew[i] < top) top = yNew[i];
                if (yNew[i] > bot) bot = yNew[i];
                if (cols[i] < cMin) cMin = cols[i];
                if (cols[i] > cMax) cMax = cols[i];
            }
            int h = bot - top + 1;
            if (h > dstR) {
                // 太高：放得下的图标原地不动，只把溢出的那几个挪走——
                // 先填簇自身范围内的空洞，还不够就在簇右侧追加新列（右边的东西随之右推）
                foreach (int i in mem) yNew[i] -= top;
                HashSet<long> taken = new HashSet<long>();
                List<int> over = new List<int>();
                foreach (int i in mem) {
                    if (yNew[i] < dstR && taken.Add(Key(cols[i], yNew[i]))) continue;
                    over.Add(i);
                }
                over.Sort(delegate(int a, int b) {
                    if (cols[a] != cols[b]) return cols[a].CompareTo(cols[b]);
                    if (yNew[a] != yNew[b]) return yNew[a].CompareTo(yNew[b]);
                    return a.CompareTo(b);
                });
                int next = 0;
                for (int c = cMin; c <= cMax && next < over.Count; c++) {
                    for (int r = 0; r < dstR && next < over.Count; r++) {
                        if (taken.Contains(Key(c, r))) continue;
                        int i = over[next++];
                        effCol[i] = c; yNew[i] = r;
                        taken.Add(Key(c, r));
                    }
                }
                int rest = over.Count - next;
                for (int j = 0; j < rest; j++) {
                    int i = over[next + j];
                    appendAfter[i] = cMax;
                    appendOff[i] = j / dstR;
                    yNew[i] = j % dstR;
                }
                if (rest > 0) { insAfter.Add(cMax); insCount.Add((rest + dstR - 1) / dstR); }
            } else if (bot >= dstR) {
                int shift = bot - dstR + 1;
                foreach (int i in mem) yNew[i] -= shift;
            } else if (top < 0) {
                foreach (int i in mem) yNew[i] -= top;
            }
        }

        // ---- X 轴（含折行插入的列）----
        int totalIns = 0;
        foreach (int e in insCount) totalIns += e;
        int[] xInter = new int[n];
        for (int i = 0; i < n; i++) {
            int baseCol = (appendOff[i] >= 0) ? appendAfter[i] : effCol[i];
            int shift = 0;
            for (int t = 0; t < insAfter.Count; t++) if (insAfter[t] < baseCol) shift += insCount[t];
            xInter[i] = baseCol + shift + ((appendOff[i] >= 0) ? 1 + appendOff[i] : 0);
        }
        int[] xNew = MapAxis(xInter, srcC + totalIns, dstC);

        for (int i = 0; i < n; i++) {
            outC[i] = xNew[i];
            outR[i] = yNew[i];
            outCluster[i] = cid[i];
        }
    }

    static int[] MapAxis(int[] v, int srcN, int dstN) {
        int n = v.Length;
        int min = int.MaxValue;
        for (int i = 0; i < n; i++) if (v[i] < min) min = v[i];
        int off = (min < 0) ? -min : 0;   // 出现负坐标时整体平移到 0 起
        SortedSet<int> set = new SortedSet<int>();
        for (int i = 0; i < n; i++) set.Add(v[i] + off);
        int[] used = new int[set.Count];
        set.CopyTo(used);
        int[] mapped = ElasticMap(used, srcN + off, dstN);
        Dictionary<int, int> map = new Dictionary<int, int>();
        for (int i = 0; i < used.Length; i++) map[used[i]] = mapped[i];
        int[] res = new int[n];
        for (int i = 0; i < n; i++) res[i] = map[v[i] + off];
        return res;
    }

    // ------------------------------------------------------------------
    // 调试用：把网格画成字符图。marks[i] 是第 i 个图标显示的字符。
    // ------------------------------------------------------------------
    public static string Render(int C, int R, int[] cols, int[] rows, char[] marks) {
        char[,] g = new char[R, C];
        for (int r = 0; r < R; r++) for (int c = 0; c < C; c++) g[r, c] = '.';
        int outside = 0, clash = 0;
        for (int i = 0; i < cols.Length; i++) {
            int c = cols[i], r = rows[i];
            if (c < 0 || r < 0 || c >= C || r >= R) { outside++; continue; }
            if (g[r, c] != '.') { g[r, c] = '#'; clash++; continue; }
            g[r, c] = marks[i];
        }
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        sb.Append('+').Append('-', C).Append("+\n");
        for (int r = 0; r < R; r++) {
            sb.Append('|');
            for (int c = 0; c < C; c++) sb.Append(g[r, c]);
            sb.Append("|\n");
        }
        sb.Append('+').Append('-', C).Append('+');
        if (outside > 0 || clash > 0) sb.Append("  越界 " + outside + "，重叠 " + clash);
        return sb.ToString();
    }
}

// ----------------------------------------------------------------------
// 在一个 C×R 网格上落位，支持整簇推挤与单个找空位
// ----------------------------------------------------------------------
public sealed class DikPlacer {
    readonly int cols;
    readonly int rows;
    readonly bool[] occ;
    public int Collisions;   // 网格满了实在放不下、只能重叠的数量

    public DikPlacer(int c, int r) {
        cols = Math.Max(1, c);
        rows = Math.Max(1, r);
        occ = new bool[cols * rows];
    }

    public int Cols { get { return cols; } }
    public int Rows { get { return rows; } }

    public bool IsFree(int c, int r) {
        return c >= 0 && r >= 0 && c < cols && r < rows && !occ[r * cols + c];
    }

    public void Occupy(int c, int r) {
        if (c >= 0 && r >= 0 && c < cols && r < rows) occ[r * cols + c] = true;
    }

    /// 单个图标：理想位置空着就用，否则找最近的空格（同列优先、先下后上、先右后左）
    public void PlaceSingle(int c, int r, out int oc, out int orow) {
        c = Clamp(c, 0, cols - 1);
        r = Clamp(r, 0, rows - 1);
        if (IsFree(c, r)) { Occupy(c, r); oc = c; orow = r; return; }
        int maxD = cols + rows;
        for (int d = 1; d <= maxD; d++) {
            for (int adx = 0; adx <= d; adx++) {
                int ady = d - adx;
                // 顺序：(+dy) (-dy)，先右 (+dx) 后左
                for (int sx = 0; sx < 2; sx++) {
                    int dx = (sx == 0) ? adx : -adx;
                    if (sx == 1 && adx == 0) continue;
                    for (int sy = 0; sy < 2; sy++) {
                        int dy = (sy == 0) ? ady : -ady;
                        if (sy == 1 && ady == 0) continue;
                        if (IsFree(c + dx, r + dy)) {
                            oc = c + dx; orow = r + dy; Occupy(oc, orow); return;
                        }
                    }
                }
            }
        }
        Collisions++;
        oc = c; orow = r;
    }

    /// 一组图标（带簇编号）：大簇先放；每簇优先整体平移到最近的可用位置，放不下再拆散
    public void PlaceClusters(int[] c, int[] r, int[] cluster, int[] outC, int[] outR) {
        int n = c.Length;
        Dictionary<int, List<int>> groups = new Dictionary<int, List<int>>();
        List<int> keys = new List<int>();
        for (int i = 0; i < n; i++) {
            List<int> l;
            if (!groups.TryGetValue(cluster[i], out l)) { l = new List<int>(); groups[cluster[i]] = l; keys.Add(cluster[i]); }
            l.Add(i);
        }
        keys.Sort(delegate(int a, int b) {
            int ca = groups[a].Count, cb = groups[b].Count;
            if (ca != cb) return cb.CompareTo(ca);
            int ma = MinOf(groups[a], c), mb = MinOf(groups[b], c);
            if (ma != mb) return ma.CompareTo(mb);
            return MinOf(groups[a], r).CompareTo(MinOf(groups[b], r));
        });

        foreach (int k in keys) {
            List<int> mem = groups[k];
            int dx, dy;
            if (FindClusterOffset(mem, c, r, out dx, out dy)) {
                foreach (int i in mem) {
                    outC[i] = c[i] + dx; outR[i] = r[i] + dy;
                    Occupy(outC[i], outR[i]);
                }
            } else {
                List<int> order = new List<int>(mem);
                order.Sort(delegate(int a, int b) {
                    if (c[a] != c[b]) return c[a].CompareTo(c[b]);
                    return r[a].CompareTo(r[b]);
                });
                foreach (int i in order) {
                    int oc, orow;
                    PlaceSingle(c[i], r[i], out oc, out orow);
                    outC[i] = oc; outR[i] = orow;
                }
            }
        }
    }

    bool FindClusterOffset(List<int> mem, int[] c, int[] r, out int bestDx, out int bestDy) {
        bestDx = 0; bestDy = 0;
        int minC = int.MaxValue, maxC = int.MinValue, minR = int.MaxValue, maxR = int.MinValue;
        HashSet<long> seen = new HashSet<long>();
        foreach (int i in mem) {
            if (!seen.Add(((long)c[i] << 32) ^ (uint)r[i])) return false;   // 簇内本身就重叠，只能拆散
            if (c[i] < minC) minC = c[i];
            if (c[i] > maxC) maxC = c[i];
            if (r[i] < minR) minR = r[i];
            if (r[i] > maxR) maxR = r[i];
        }
        int w = maxC - minC + 1, h = maxR - minR + 1;
        if (w > cols || h > rows) return false;

        // 先整体挪进屏幕
        int baseDx = 0, baseDy = 0;
        if (minC < 0) baseDx = -minC; else if (maxC >= cols) baseDx = cols - 1 - maxC;
        if (minR < 0) baseDy = -minR; else if (maxR >= rows) baseDy = rows - 1 - maxR;

        // 推挤方向：往屏幕中间、空地多的一侧
        int prefX = ((minC + maxC + 2 * baseDx) < cols - 1) ? 1 : -1;
        int prefY = ((minR + maxR + 2 * baseDy) < rows - 1) ? 1 : -1;

        int maxD = cols + rows;
        for (int d = 0; d <= maxD; d++) {
            // 同等距离下：优先水平平移（保持行对齐），再优先朝 pref 方向
            for (int ady = 0; ady <= d; ady++) {
                int adx = d - ady;
                for (int sx = 0; sx < 2; sx++) {
                    if (sx == 1 && adx == 0) continue;
                    int dx = baseDx + ((sx == 0) ? prefX * adx : -prefX * adx);
                    for (int sy = 0; sy < 2; sy++) {
                        if (sy == 1 && ady == 0) continue;
                        int dy = baseDy + ((sy == 0) ? prefY * ady : -prefY * ady);
                        if (minC + dx < 0 || maxC + dx >= cols || minR + dy < 0 || maxR + dy >= rows) continue;
                        bool ok = true;
                        foreach (int i in mem) {
                            if (!IsFree(c[i] + dx, r[i] + dy)) { ok = false; break; }
                        }
                        if (ok) { bestDx = dx; bestDy = dy; return true; }
                    }
                }
            }
        }
        return false;
    }

    static int MinOf(List<int> idx, int[] v) {
        int m = int.MaxValue;
        foreach (int i in idx) if (v[i] < m) m = v[i];
        return m;
    }

    static int Clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
}
