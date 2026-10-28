#!/usr/bin/env python3
"""Prepare a provenance-preserving Clover CSV batch for the DEV importer."""
import argparse
import csv
import hashlib
import json
import re
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo('America/Chicago')


def cents(value):
    value = (value or '').strip().replace('$', '').replace(',', '')
    if value.startswith('(') and value.endswith(')'):
        value = '-' + value[1:-1]
    amount = Decimal(value or '0') * 100
    if amount != amount.to_integral_value():
        raise ValueError('Source amount has fractions of a cent')
    return int(amount)


def source_time(value):
    match = re.fullmatch(r'(.+) (CDT|CST)', value)
    if not match:
        raise ValueError('Clover timestamp must state CDT or CST')
    parsed = datetime.strptime(match[1], '%d-%b-%Y %I:%M %p').replace(tzinfo=TZ)
    if parsed.tzname() != match[2]:
        raise ValueError('Timestamp abbreviation conflicts with America/Chicago')
    return parsed


def load(path):
    raw = Path(path).read_bytes()
    meta = {'name': Path(path).name, 'sha256': hashlib.sha256(raw).hexdigest()}
    return meta, list(csv.DictReader(raw.decode('utf-8-sig').splitlines()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--business-date', required=True)
    parser.add_argument('--orders', nargs='+', required=True)
    parser.add_argument('--payments', nargs='+', required=True)
    parser.add_argument('--discounts', required=True)
    parser.add_argument('--sales-report', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    day = date.fromisoformat(args.business_date)
    start = datetime.combine(day, time(7), TZ)
    end = datetime.combine(day + timedelta(days=1), time(7), TZ)
    sources, orders, payments = [], {}, {}
    for kind, paths, key, target in [
        ('orders', args.orders, 'Order ID', orders),
        ('payments', args.payments, 'Payment ID', payments),
    ]:
        for path in paths:
            meta, rows = load(path)
            sources.append({**meta, 'kind': kind})
            for number, row in enumerate(rows, 2):
                identity = row[key]
                if not identity or row['Currency'] != 'USD':
                    raise ValueError('Missing ID or unsupported currency')
                if identity in target and target[identity]['original'] != row:
                    raise ValueError('Conflicting exported rows for ' + identity)
                target[identity] = {'original': row, 'source': {**meta, 'row': number}}
    selected = []
    for identity, item in sorted(payments.items()):
        row = item['original']
        at = source_time(row['Payment Date'])
        if not start <= at < end:
            continue
        if row['Result'] != 'SUCCESS' or cents(row['Refund Amount']) != 0:
            raise ValueError('Refund/reversal source IDs required for ' + identity)
        if cents(row['Service Charge Amount']) != 0:
            raise ValueError('Service-charge allocation required for ' + identity)
        if row['Order ID'] not in orders:
            raise ValueError('Missing related order ' + row['Order ID'])
        selected.append({
            'id': identity, 'order_id': row['Order ID'], 'created_at': at.isoformat(),
            'timestamp_precision': 'minute', 'currency': row['Currency'],
            'amount_cents': cents(row['Amount']), 'tax_cents': cents(row['Tax Amount']),
            'tip_cents': cents(row['Tip Amount']), 'refund_cents': 0,
            'employee_id': row['Payment Employee ID'] or None,
            'employee_name': row['Payment Employee Name'] or None,
            'tender': row['Tender'], 'result': row['Result'], 'source': item['source'],
            'fields': {k: row[k] for k in ['Payment Date', 'Payment ID', 'Order ID',
                'Order Date', 'Currency', 'Amount', 'Tax Amount', 'Tip Amount',
                'Service Charge Amount', 'Payment Employee ID', 'Payment Employee Name',
                'Tender', 'Result', '# Refunds', 'Refund Amount']},
        })
    selected_orders = []
    relevant = {r['order_id'] for r in selected}
    for identity in sorted(relevant):
        item = orders[identity]
        row = item['original']
        selected_orders.append({
            'id': identity, 'created_at': source_time(row['Order Date']).isoformat(),
            'timestamp_precision': 'minute', 'total_cents': cents(row['Order Total']),
            'tax_cents': cents(row['Tax Amount']), 'discount_cents': cents(row['Discount']),
            'employee_id': row['Order Employee ID'] or None,
            'payment_state': row['Order Payment State'], 'source': item['source'],
            'fields': {k: row[k] for k in ['Order Date', 'Order ID', 'Currency',
                'Tax Amount', 'Tip', 'Service Charge', 'Discount', 'Order Total',
                'Payments Total', 'Refunds Total', 'Manual Refunds Total',
                'Order Employee ID', 'Order Employee Name', 'Order Payment State']},
        })
    def report_rows(path, kind):
        raw = Path(path).read_bytes()
        meta = {'name': Path(path).name, 'sha256': hashlib.sha256(raw).hexdigest(), 'kind': kind}
        sources.append(meta)
        rows = list(csv.reader(raw.decode('utf-8-sig').splitlines()))
        if len(rows) < 2 or not rows[1] or f"{day.strftime('%b')} {day.day}, {day.year}" not in rows[1][0]:
            raise ValueError('Report does not identify the selected business date')
        if '7:00 AM' not in rows[1][0] or '6:59 AM' not in rows[1][0]:
            raise ValueError('Report must cover the 7 AM business day')
        return rows, meta
    discount_rows, discount_meta = report_rows(args.discounts, 'discount_report')
    discounts = []
    for number, row in enumerate(discount_rows, 1):
        if len(row) < 8 or not row[0] or row[0] in ('Total', 'Discount'):
            continue
        if not row[2].startswith('$'):
            continue
        for scope, amount_index, count_index in [('ORDER', 2, 3), ('ITEM', 4, 5)]:
            amount = cents(row[amount_index])
            if amount:
                discounts.append({'name': row[0], 'scope': scope, 'amount_cents': amount,
                    'record_count': int(row[count_index]), 'granularity': 'REPORT_DISCOUNT_GROUP',
                    'source': {**discount_meta, 'row': number}, 'source_order_id': None,
                    'source_employee_id': None})
    sales_rows, sales_meta = report_rows(args.sales_report, 'sales_report')
    labels = {'Gross sales': 'gross_sales_cents', 'Discounts': 'discount_cents',
        'Refunds': 'refund_cents', 'Net sales': 'net_sales_cents', 'Taxes': 'tax_cents',
        'Tips': 'tip_cents', 'Amount collected': 'collected_cents',
        'Credit and debit cards': 'card_cents', 'Cash': 'cash_cents'}
    reference = {}
    for row in sales_rows:
        if len(row) < 2:
            continue
        if row[0] in labels:
            reference[labels[row[0]]] = abs(cents(row[1]))
        if row[0] == 'Net sales' and len(row) > 2:
            count = re.fullmatch(r'from (\d+) orders', row[2])
            if count:
                reference['reported_order_count'] = int(count[1])
    if set(reference) != set(labels.values()) | {'reported_order_count'}:
        raise ValueError('Sales report is missing required reference fields')
    batch = {'schema_version': 1, 'business_date': day.isoformat(),
        'window_start': start.isoformat(), 'window_end': end.isoformat(),
        'timezone': 'America/Chicago', 'sources': sorted(sources, key=lambda x: x['name']),
        'orders': selected_orders, 'payments': selected, 'discount_groups': discounts,
        'reference': reference, 'sales_recognition': 'NOT_POSTED_PENDING_ORDER_LINE_ALLOCATION',
        'excluded_opening_window_orders': [identity for identity, item in sorted(orders.items())
            if identity not in relevant and start <= source_time(item['original']['Order Date']) < end]}
    fingerprint = hashlib.sha256(json.dumps(batch, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    batch['source_set_sha256'] = fingerprint
    Path(args.output).write_text(json.dumps(batch, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'output': args.output, 'business_date': day.isoformat(),
        'orders': len(selected_orders), 'payments': len(selected), 'discount_groups': len(discounts)}))


if __name__ == '__main__':
    main()
