import copy
import json
from pathlib import Path
import unittest
from airs.coverage import coverage_inventory

ROOT=Path(__file__).resolve().parents[1]

class CoverageTests(unittest.TestCase):
    def test_saved_report_denominator_reasons_and_duplicate_accounting(self):
        report=json.loads((ROOT/'examples/mixed.audit.json').read_text())
        result=coverage_inventory([report,copy.deepcopy(report)])
        self.assertEqual(result['summary']['input_report_count'],2)
        self.assertEqual(result['summary']['duplicate_report_count'],1)
        self.assertEqual(result['summary']['function_count'],9)
        self.assertEqual(result['summary']['unresolved_count'],4)
        self.assertEqual(sum(row['count'] for row in result['reasons']),4)
        self.assertTrue(all(row['examples'] for row in result['reasons']))

    def test_conflicting_results_and_configurations_are_never_silently_deduplicated(self):
        report=json.loads((ROOT/'examples/mixed.audit.json').read_text())
        conflict=copy.deepcopy(report);conflict['findings'][-1]['reason_codes']=['another_unknown']
        result=coverage_inventory([report,conflict])
        self.assertEqual(result['status'],'conflicting_reports')
        self.assertEqual(result['summary']['conflicting_report_count'],2)
        self.assertEqual(result['summary']['function_count'],18)
        other=copy.deepcopy(report);other['analysis_config']['limits']['max_functions']-=1
        result=coverage_inventory([report,other])
        self.assertEqual(result['summary']['unique_image_model_config_count'],2)
        self.assertEqual(result['summary']['function_count'],18)
