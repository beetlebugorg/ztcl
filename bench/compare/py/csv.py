# Reads a CSV file of sales and writes the quantity and the revenue for
# each region and product.
import csv, os, sys
qty, rev = {}, {}
total_qty, total_rev = 0, 0.0
with open(os.path.join(sys.argv[1], "sales.csv"), newline="") as f:
    r = csv.reader(f)
    next(r)
    for date, region, product, q, price in r:
        q = int(q)
        v = q * float(price)
        key = region + "|" + product
        qty[key] = qty.get(key, 0) + q
        rev[key] = rev.get(key, 0.0) + v
        total_qty += q
        total_rev += v
for key in sorted(qty):
    print("%s|%d|%.2f" % (key, qty[key], rev[key]))
print("TOTAL|%d|%.2f" % (total_qty, total_rev))
