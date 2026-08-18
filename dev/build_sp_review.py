# -*- coding: utf-8 -*-
"""Build the complete 54-topic stored-procedure coverage and quality review."""
from __future__ import annotations

import collections
import datetime as dt
import io
import json
import os
import re


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = os.path.join(ROOT, "data", "schema.js")
PHASES = os.path.join(ROOT, "data", "phases.js")
SQL_DIR = os.path.join(ROOT, "dev", "fcap1a_utf8")
OUT = os.path.join(ROOT, "data", "sp_review.js")


def load_js(path):
    text = io.open(path, encoding="utf-8").read()
    match = re.search(r"=\s*(\{.*\});", text, re.S)
    if not match:
        raise SystemExit("Cannot parse " + path)
    return json.loads(match.group(1))


# event_based, model, grain, canonical/desired event time, rationale
MODEL = {
    "adt": (True, "event", "one row per admission, discharge, or transfer transition", "EventDateTime", "ADT changes are time-ordered encounter events."),
    "allergies": (True, "hybrid", "one row per allergy or adverse-reaction assertion", "AllergyDateTime", "Allergies have a documentation event and a continuing active/inactive state."),
    "clinicalnotes": (True, "event", "one row per authored document or note version", "DocumentDateTime", "A note is an authored clinical event and later versions must remain distinguishable."),
    "diagnosis": (True, "hybrid", "one row per encounter diagnosis or longitudinal problem assertion", "DiagnosisDateTime", "Encounter diagnoses are events; problem-list entries are longitudinal state."),
    "encounter": (True, "event", "one row per patient visit or encounter", "AdmitDateTime", "The encounter is the primary event container for visit-grained domains."),
    "vitals": (True, "event", "one row per vital-sign observation", "ObservationDateTime", "Every measurement requires the time it was clinically observed."),
    "immunizations": (True, "event", "one row per administered, offered, or read vaccine event", "EventDateTime", "Administration and read times establish the vaccine event chronology."),
    "lab": (True, "event", "one row per laboratory test result or result component", "ResultDateTime", "Collection, result, and verification times define the laboratory event lifecycle."),
    "medications": (True, "hybrid", "one row per medication order or administration event", "AdministrationDateTime", "Orders express intent; administrations are actual clinical events."),
    "pathology": (True, "event", "one row per specimen report, sign-out, or text block", "ClinicalDateTime", "Specimen collection and final sign-out are distinct dated events."),
    "demographics": (False, "snapshot", "one row per mastered patient identity", "ExtractedOn", "Demographics represent the current patient master, not a clinical event stream."),
    "ppi": (True, "hybrid", "one row per patient-provided response or effective preference", "ResponseDateTime", "Responses are captured events while preferences and contacts remain effective state."),
    "procedures": (True, "event", "one row per performed clinical procedure or intervention", "ProcedureDateTime", "A performed procedure is event-based and must retain its clinical time."),
    "radiology": (True, "event", "one row per imaging study or final report", "StudyDateTime", "Imaging acquisition and report finalisation are dated events."),
    "problemlist": (False, "snapshot", "one row per current patient problem and status", "OnsetDateTime", "The primary contract is longitudinal problem state with onset/resolution attributes."),
    "appointments": (True, "event", "one row per scheduled appointment occurrence", "AppointmentDateTime", "Appointments are scheduled events, including cancelled and no-show outcomes."),
    "providers": (False, "reference", "one row per provider or specialty reference", "ExtractedOn", "Provider and specialty masters are reference data rather than patient events."),
    "family": (False, "snapshot", "one row per patient-relative-condition assertion", "RecordedDateTime", "Family history is a longitudinal assertion unless change history is explicitly available."),
    "micro": (True, "event", "one row per organism finding or culture result", "ResultDateTime", "Culture findings are specimen-linked laboratory events."),
    "transfusion": (True, "event", "one row per blood-bank test or transfusion-related result", "ResultDateTime", "Blood-bank activity is encounter and specimen event data."),
    "treatmentplan": (True, "hybrid", "one row per plan, cycle, problem, or plan activity", "ClinicalDateTime", "Plans are effective state; cycles and plan activities are events."),
    "medorders": (True, "event", "one row per medication order", "OrderDateTime", "Medication orders are timestamped intent events distinct from administrations."),
    "procorders": (True, "event", "one row per procedure order", "OrderDateTime", "Procedure orders are timestamped requests and require order status history."),
    "claims": (True, "event", "one row per claim header, version, or billable line", "ClaimDate", "Claims are effective-dated financial transactions with version history."),
    "ecgecho": (True, "event", "one row per ECG or echo study", "StudyDateTime", "Each cardiology study is a dated diagnostic event."),
    "infusions": (True, "event", "one row per infusion episode or rate segment", "AdministrationStartDateTime", "Infusions are time-bounded administrations and may have multiple rate events."),
    "insurance": (False, "snapshot", "one row per patient coverage and payer priority", "CoverageEffectiveDate", "Insurance is effective-dated coverage state rather than a clinical event."),
    "pft": (True, "event", "one row per pulmonary function study or measurement set", "StudyDateTime", "A PFT is a dated diagnostic study."),
    "rhc": (True, "event", "one row per catheterisation measurement set", "MeasurementDateTime", "RHC measurements occur within a dated procedure event."),
    "social": (False, "snapshot", "one row per patient social-history assertion", "RecordedDateTime", "Social history is typically current asserted state with optional observed dates."),
    "surgery": (True, "event", "one row per surgical case", "SurgeryStartDateTime", "A surgical case is a scheduled and performed event linked to an encounter."),
    "dicom": (True, "event", "one row per DICOM instance or series", "AcquisitionDateTime", "Image acquisition is an event; identifiers must preserve study/series/instance hierarchy."),
    "ct": (True, "event", "one row per CT study", "StudyDateTime", "A CT examination is a dated imaging event."),
    "pet": (True, "event", "one row per PET study", "StudyDateTime", "A PET examination is a dated imaging event."),
    "mri": (True, "event", "one row per MRI study", "StudyDateTime", "An MRI examination is a dated imaging event."),
    "echo": (True, "event", "one row per echocardiogram study", "StudyDateTime", "An echocardiogram is a dated diagnostic event."),
    "gi": (True, "event", "one row per endoscopy procedure", "ProcedureDateTime", "Endoscopy is a performed procedure event with findings and interventions."),
    "us": (True, "event", "one row per ultrasound study", "StudyDateTime", "An ultrasound examination is a dated imaging event."),
    "cath": (True, "event", "one row per cardiac catheterisation study", "ProcedureDateTime", "Cath imaging belongs to a dated invasive procedure event."),
    "mammo": (True, "event", "one row per mammography study", "StudyDateTime", "Mammography is a dated imaging event with screening/diagnostic intent."),
    "dpath": (True, "event", "one row per digital slide or scan", "ScanDateTime", "Whole-slide creation is a specimen-linked imaging event."),
    "ob": (True, "event", "one row per pregnancy, labour, or delivery event", "DeliveryDateTime", "Delivery and labour milestones form an event timeline."),
    "derm": (True, "event", "one row per dermatology image capture", "CaptureDateTime", "Clinical photography is a dated capture event."),
    "eye": (True, "event", "one row per ophthalmic imaging study", "StudyDateTime", "Fundus and OCT studies are dated imaging events."),
    "vaccines": (True, "event", "one row per vaccine administration", "EventDateTime", "Vaccination is the administered-event subset of immunisation data."),
    "otherreports": (True, "event", "one row per generated clinical report", "ReportDateTime", "A report is a dated document event and should retain version/final status."),
    "registries": (True, "hybrid", "one row per registry enrolment or registry observation", "EnrollmentDateTime", "Enrolment is an event; registry membership is continuing state."),
    "orders": (True, "event", "one row per clinical order", "OrderDateTime", "Orders are timestamped intent events with lifecycle status."),
    "xray": (True, "event", "one row per radiography study", "StudyDateTime", "An X-ray examination is a dated imaging event."),
    "meddevice": (True, "hybrid", "one row per implanted device and status interval", "ImplantDateTime", "Implantation is an event while active device status is effective state."),
    "genomics": (True, "event", "one row per genomic specimen, assay, or result", "ResultDateTime", "Genomic results are specimen-linked laboratory events."),
    "biorepo": (True, "event", "one row per collected specimen or aliquot", "CollectionDateTime", "Biorepository holdings originate from dated collection and processing events."),
    "eeg": (True, "event", "one row per EEG study", "StudyDateTime", "An EEG is a dated diagnostic study with report and signal assets."),
    "surgvideo": (True, "event", "one row per surgical video asset", "ProcedureDateTime", "A surgical video is linked to a dated procedure and media capture."),
}


PROPOSED = {
    "ecgecho": "FCAP1A_ECGAndEcho", "infusions": "FCAP1A_Infusions",
    "pft": "FCAP1A_PulmonaryFunctionTests", "rhc": "FCAP1A_RHCMeasurements",
    "social": "FCAP1A_SocialHistory", "dicom": "FCAP1A_DICOMHeaders",
    "ct": "FCAP1A_CTImaging", "pet": "FCAP1A_PETImaging", "mri": "FCAP1A_MRIImaging",
    "echo": "FCAP1A_Echocardiograms", "gi": "FCAP1A_GIEndoscopy",
    "us": "FCAP1A_UltrasoundImaging", "cath": "FCAP1A_CardiologyCathImaging",
    "mammo": "FCAP1A_Mammography", "dpath": "FCAP1A_DigitalPathology",
    "ob": "FCAP1A_OBDelivery", "derm": "FCAP1A_DermatologyImaging",
    "eye": "FCAP1A_EyeImaging", "xray": "FCAP1A_XRayImaging",
    "meddevice": "FCAP1A_MedicalDevices", "genomics": "FCAP1A_Genomics",
    "biorepo": "FCAP1A_Biorepository", "eeg": "FCAP1A_EEG",
    "surgvideo": "FCAP1A_SurgicalVideo",
}


EVIDENCE = {
    "appointments": ("direct-structured", "Appointment header, audit, and populated resource detail"),
    "problemlist": ("direct-structured", "Populated longitudinal problem sources"),
    "medorders": ("direct-structured", "Order header, lifecycle, and dictionary"),
    "procorders": ("direct-structured", "Order header, lifecycle, and dictionary"),
    "infusions": ("direct-structured", "MAR infusion, titration, prescription, and bag activity"),
    "social": ("direct-structured", "Patient and visit query responses plus query dictionary"),
    "surgery": ("direct-structured", "Surgical case, procedure, operative time, and implant sources"),
    "ob": ("direct-partial", "Pregnancy episode sources; actual delivery time is not confirmed"),
    "vaccines": ("direct-structured", "Vaccine event, dose, lot, and dictionary"),
    "otherreports": ("direct-structured", "Populated account report references"),
    "registries": ("direct-structured", "Registry membership and longitudinal observations"),
    "meddevice": ("direct-structured", "Patient and surgical implant records"),
    "ecgecho": ("generic-relational", "Order/report evidence; no waveform or structured measurements"),
    "pft": ("generic-relational", "Order/report evidence; no structured spirometry measures"),
    "rhc": ("generic-relational", "Order/report evidence; no structured haemodynamics"),
    "echo": ("generic-relational", "Order/report evidence; no structured echo measures"),
    "gi": ("generic-relational", "Order/report evidence; procedure findings need validation"),
    "genomics": ("generic-relational", "Dedicated genetic-result table is empty; using order/report evidence"),
}
for _topic in ("dicom", "ct", "pet", "mri", "us", "cath", "mammo", "dpath", "derm", "eye", "xray", "biorepo", "eeg", "surgvideo"):
    EVIDENCE[_topic] = ("external-metadata", "Relational references only; authoritative media or inventory remains external")


SHARED_TOPIC_IDS = set()


DISCOVERY_TERMS = {
    "ecgecho": ["ECG", "ECHO"], "infusions": ["INFUS", "IV"], "pft": ["PFT", "PULMON"],
    "rhc": ["CATH", "HEMODYN"], "social": ["SOCIAL", "TOBACCO"], "dicom": ["DICOM", "PACS"],
    "ct": ["CT", "RAD"], "pet": ["PET", "NUCLEAR"], "mri": ["MRI", "RAD"],
    "echo": ["ECHO", "CARD"], "gi": ["ENDOSCOPY", "GI"], "us": ["ULTRASOUND", "SONO"],
    "cath": ["CATH", "CARD"], "mammo": ["MAMMO", "BREAST"], "dpath": ["SLIDE", "PATH"],
    "ob": ["DELIVERY", "OB"], "derm": ["DERM", "PHOTO"], "eye": ["OCT", "FUNDUS"],
    "xray": ["XRAY", "RAD"], "meddevice": ["DEVICE", "IMPLANT"], "genomics": ["GENOMIC", "DNA"],
    "biorepo": ["SPECIMEN", "ALIQUOT"], "eeg": ["EEG", "NEURO"], "surgvideo": ["VIDEO", "SURG"],
}


# Curated, evidence-based suggestions keyed by primary procedure name.
CURATED_SUGGESTIONS = {
    "usp_Build_FCAP1A_ClinicalNotes_Extended": [
        {"check": 2, "note": "Window filter uses t.RowUpdateDateTime (line ~194); use the document time EmrDocData_Main.DateTime (alias m) for the extraction window and keep RowUpdateDateTime only for line de-duplication ordering."},
        {"check": 3, "note": "DocumentID is cast from EmrDocDataID; confirm EmrDocDataID is globally unique so the (PatientID, DocumentID) primary key cannot collide across sources."},
    ],
    "usp_Build_FCAP1A_ClinicalNarrative_Extended": [
        {"check": 2, "note": "Window filter uses t.RowUpdateDateTime; use the document/report clinical time for the extraction window and RowUpdateDateTime only for de-duplication."},
    ],
    "usp_Build_FCAP1A_Diagnoses_Extended": [
        {"check": 2, "note": "Window filter uses d.RowUpdateDateTime (lines ~448-450) instead of the clinical diagnosis time; AbsAcct_Diagnoses.DiagnosisEffectiveDateID is already exposed in the output, so window on it (or union both) to keep in-window effective diagnoses whose row was last updated outside the window."},
        {"check": 3, "note": "SELECT DISTINCT protects against join expansion but also hides real duplicates; verify the visit-diagnosis grain (SourceID + VisitID + DiagnosisUrnID + SortOrder) with a natural-key duplicate query instead."},
    ],
    "usp_Build_FCAP1A_Encounters_Extended": [
        {"check": 3, "note": "Window predicate uses BETWEEN @WindowStart AND @WindowEndNextDay (line ~486); use >= @WindowStart AND < @WindowEndNextDay so StartDateTime on the day after @WindowEnd is excluded."},
        {"check": 4, "note": "AdmBase LEFT JOIN adds a.SourceID = r.SourceID (line ~472) on top of VisitID; the visit is anchored on PatientID + VisitID (PI + VI), so SourceID is redundant in the predicate — drop it (both CTEs partition by SourceID + VisitID, so confirm VisitID is unique across the two source systems before relying on VisitID alone)."},
        {"check": 3, "note": "StartDateTime is a CASE over Admit/Arrival/Service time and the window filters on it (line ~486); visits where all three times are NULL are silently excluded. Confirm whether encounters without an admission/arrival/service time should be dropped or retained with a NULL StartDateTime."},
    ],
    "usp_Build_FCAP1A_Flowsheets_Extended": [
        {"check": 1, "note": "Vitals are event-based (one row per observation) but the build is a per-visit snapshot: PK (PatientID, VisitID) with a single BloodPressure/Pulse/Temperature per row, so multiple observations per visit collapse and the observation timeline is lost. Re-grain to one row per observation (observation time + source rowid) or change the topic contract to a per-visit snapshot."},
        {"check": 2, "note": "Observation time has no dedicated source column: PhaPatData/AdmVitalSigns expose only RowUpdateDateTime; the COALESCE(LastEventDateTime, ErTriageDateTime, RowUpdateDateTime) window proxy should be documented as the observation-time contract."},
        {"check": 3, "note": "The header comment and log remark document the fixed window as 2022-11-05 to 2026-01-31, but @WindowEnd is hard-coded 2026-06-14 (line ~74); update the stale comments to match the executed window (or align the constant)."},
        {"check": 4, "note": "SELECT DISTINCT with PK (PatientID, VisitID): two observations for the same visit that differ in any measurement remain distinct rows and collide on the PK (the insert fails), while identical rows collapse. Fan-out from PhaPatData/AdmVitalSigns (multiple rows per visit) must be reduced before DISTINCT."},
    ],
    "usp_Build_FCAP1A_Immunizations_Extended": [
        {"check": 2, "note": "EventDateTime is COALESCE(GivenDateTime, ReadDateTime, RowUpdateDateTime) (line ~250) and the window reuses the same expression (lines ~306-308), so the event time and window are consistent; document that RowUpdateDateTime is the event time for rows that were never administered or read (offered/read events)."},
        {"check": 3, "note": "13 output columns are populated with hard-coded NULL (EligibilityStatus, EligibilityDateTime, FundingSourceID, VaccineFundingSourceID, ManufactureFree, DeliveryMgmtSiteMnemonicID, InjectionSite, InjectionAdminSiteID, VisGivenDateTime, VisPubDateTime, VirusInfoGivenDateTime, VirusInfoPublicationDateTime, MultiDoseLotDoseSummary); they belong to the six unread contract sources, so column completeness equals the missing-source gap."},
        {"check": 4, "note": "The only SourceID join is the DPhaDrugData dictionary lookup (b.SourceID = d.SourceID AND b.DrugID = d.DrugID, line ~394): SourceID is part of the per-source drug-dictionary key and must be retained — it is a legitimate key, not a redundant predicate."},
    ],
    "usp_Build_FCAP1A_Labs_Extended": [
        {"check": 4, "note": "LEFT JOIN #Micro on (SourceID, SpecimenID, VisitID) (lines ~590-596) fans out each result once per isolated organism; a specimen with several organisms duplicates the same NumericResult per organism. Keep organisms in their own table (or aggregate them) so the one-row-per-result grain holds."},
        {"check": 4, "note": "Every specimen join uses SourceID + SpecimenID (specimen IDs are source-scoped), so SourceID is load-bearing in these joins and must be retained — a legitimate per-source specimen key, not a redundant predicate."},
        {"check": 3, "note": "The results stage windows on COALESCE(ResultDateTime, RowUpdateDateTime) (lines ~408-410); rows that qualify only via RowUpdateDateTime are emitted with a NULL ResultDateTime, leaving the canonical event field empty."},
    ],
    "usp_Build_FCAP1A_Medications_Extended": [
        {"check": 4, "note": "All joins use source-scoped keys — SourceID + PrescriptionID (PhaRx, PhaRxMedications, PhaRxAdministrations, PhaRxScannedMedPatientX) and SourceID + DrugID/GenericID (DPhaDrugData, DPhaGeneric dictionaries). SourceID is load-bearing here (prescription and drug IDs are per-source) and must be retained."},
        {"check": 4, "note": "AdminEvents joins #Admin INNER JOIN #Rx on (SourceID, PrescriptionID) (line ~578): administrations whose prescription order falls outside the #Rx window are dropped even when the administration time is inside the window; consider a LEFT JOIN so in-window administrations of older orders are not lost."},
    ],
    "usp_Build_FCAP1A_MedicalDevices": [
        {"check": 2, "note": "Surgical-implant ImplantDateTime is mapped from CwsAppt_Main.DateTime (appointment time); confirm SurCase_Implant has no true implant date (ImplantManufacturedDate/ImplantsExpirationDate are dates but not the implant time)."},
        {"check": 3, "note": "No window predicate is applied on ImplantDateTime; the procedure builds the full device history regardless of @WindowStart/@WindowEnd."},
    ],
    "usp_Build_FCAP1A_PatientInsurance": [
        {"check": 1, "note": "Snapshot topic filters on COALESCE(PolicyEffectiveDate, InsuranceExpirationDate, RowUpdateDateTime) with a lower bound; older coverage that is still valid but was never updated inside the window is dropped. For a snapshot contract, do not lower-bound on row-update time."},
    ],
    "usp_Build_FCAP1A_FamilyMedicalHistory": [
        {"check": 1, "note": "Snapshot topic windows on COALESCE(FirstRecordedDate, LastRecordedDate, RowUpdateDateTime); a lower bound drops older valid family assertions not updated inside the window."},
        {"check": 4, "note": "MemberComments CTE joins on (PatientID, SourceID, MemberNumberID); drop SourceID from the join — the family-member key is PatientID + MemberNumberID (PI-anchored), so SourceID is redundant in the predicate."},
    ],
}


def load_sql_text(asset):
    path = os.path.join(SQL_DIR, asset["file"])
    return io.open(path, encoding="utf-8-sig", errors="replace").read()


def proc_header(text):
    match = re.search(r"\b(CREATE\s+OR\s+ALTER|CREATE|ALTER)\s+PROCEDURE\s+(?:\[?dbo\]?\.)?\[?([A-Za-z0-9_]+)\]?", text, re.I)
    if not match:
        return "none", None, []
    style = " ".join(match.group(1).upper().split())
    tail = text[match.end():]
    as_match = re.search(r"\bAS\b", tail[:3000], re.I)
    header = tail[:as_match.start()] if as_match else ""
    params = sorted(set(re.findall(r"@[A-Za-z0-9_]+", header)))
    return style.lower().replace(" ", "-"), match.group(2), params


def sql_sources(text, tables):
    found = []
    for match in re.finditer(r"\b(?:FROM|JOIN)\s+([A-Za-z0-9_\[\].]+)", text, re.I):
        name = match.group(1).split(".")[-1].strip("[]")
        if name in tables and not name.startswith("tbl_FCAP1A_") and name not in found:
            found.append(name)
    return found


CHECKS = {
    1: "Event-driven vs non-event-driven handling",
    2: "Event-date column selection",
    3: "Completeness (columns, rows, WHERE filters)",
    4: "Join correctness, duplication/dropped-record risk, SourceID removal from joins",
    5: "Topic source contract coverage",
}


def window_bounds(text):
    has_ws = bool(re.search(r"@WindowStart", text, re.I))
    has_predicate = bool(re.search(r"(?:>=|<=|>|<|BETWEEN)\s*@WindowStart", text, re.I))
    excl = bool(re.search(r"<\s*@WindowEnd(?:NextDay|Plus1)?\b", text, re.I)) or bool(re.search(r"<\s*DATEADD\(\s*DAY\s*,\s*1\s*,", text, re.I))
    incl = bool(re.search(r"BETWEEN\s+@WindowStart\s+AND\s+@WindowEnd(?:NextDay|Plus1)?\b", text, re.I))
    return excl, incl, has_ws and has_predicate and not excl and not incl


def window_time_cols(text):
    cols = []
    pred_pat = re.compile(r"([^;\n]{0,120}?(?:>=|<=|>|<)\s*@WindowStart)", re.I)
    for m in pred_pat.finditer(text):
        snippet = m.group(1)
        for c in re.findall(r"([A-Za-z_][A-Za-z0-9_]*\.(?:RowUpdateDateTime|DateTime|DateID|[A-Za-z0-9_]*Date[A-Za-z0-9_]*|ResultDateTime|OrderDatetime|ClinicalDateTime|AdmitDateTime|ServiceDateTime|ArrivalDateTime|StudyDateTime|EventDateTime))", snippet):
            if c not in cols:
                cols.append(c)
    return cols


def direct_rowupdate_filter(text):
    return bool(re.search(r"\b\w+\.RowUpdateDateTime\s*(?:>=|<=|>|<)\s*@WindowStart", text, re.I))


def sourceid_join_details(text):
    """Return {joined_table: ([entity keys paired with SourceID], anchored)}.

    anchored=True when the join's ON clause also references PatientID/VisitID, so
    SourceID is redundant there. anchored=False means SourceID is the source-scoping
    key (per-source entity IDs like claims, specimens, prescriptions, dictionaries)
    and is load-bearing.
    """
    found = {}
    pat = re.compile(r"\b(?:INNER|LEFT|RIGHT|FULL|CROSS|OUTER)?\s*JOIN\b[^()]*?\bON\b[^()]*?(?=\s*(?:JOIN|INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|WHERE|GROUP\s+BY|ORDER\s+BY|HAVING|;))", re.I | re.S)
    for m in pat.finditer(text):
        chunk = " ".join(m.group(0).split())
        if "SourceID" not in chunk:
            continue
        name_match = re.search(r"JOIN\s+\[?([\w.]+)\]?[\w\s]*\bON\b", chunk, re.I)
        if not name_match:
            continue
        name = name_match.group(1).split(".")[-1]
        if not name or name in found:
            continue
        keys = []
        for col in re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)", chunk):
            if col != "SourceID" and col.endswith("ID") and col not in keys:
                keys.append(col)
        anchored = bool(re.search(r"\b(?:PatientID|VisitID)\b", chunk))
        found[name] = (keys, anchored)
    return found


def sql_review_suggestions(proc, text, event_based, canonical_time):
    """Suggestions for the four review checks, grounded in static SQL inspection."""
    suggestions = []
    excl, incl, lower_only = window_bounds(text)
    time_cols = window_time_cols(text)
    row_update_used = direct_rowupdate_filter(text)
    if incl:
        suggestions.append({"check": 3, "note": "Window predicate uses BETWEEN @WindowStart AND @WindowEndNextDay, which includes the day after @WindowEnd; prefer an exclusive upper bound (>= @WindowStart AND < @WindowEndNextDay)."})
    if lower_only:
        suggestions.append({"check": 3, "note": "Window predicate applies only a lower bound (>= @WindowStart); add an exclusive upper bound (< @WindowEndNextDay) so post-window rows are excluded."})
    if row_update_used and canonical_time and canonical_time.lower() != "rowupdatedatetime":
        suggestions.append({"check": 2, "note": f"Window filter is driven by a RowUpdateDateTime column; consider using the canonical clinical time ({canonical_time}) for the extraction window and RowUpdateDateTime only for de-duplication ordering."})
    has_ws = bool(re.search(r"@WindowStart", text, re.I))
    has_predicate = bool(re.search(r"(?:>=|<=|>|<|BETWEEN)\s*@WindowStart", text, re.I))
    has_upper = bool(re.search(r"<\s*@WindowEnd(?:NextDay|Plus1)?\b|<\s*DATEADD\(\s*DAY\s*,\s*1\s*,", text, re.I))
    if event_based and has_ws and (not has_predicate or (has_upper and not has_predicate)):
        if has_upper and not has_predicate:
            suggestions.append({"check": 1, "note": "Event-based topic declares window parameters but the primary query applies only an upper bound on the window end; add the lower-bound predicate on @WindowStart so the extract respects the study window start."})
        else:
            suggestions.append({"check": 1, "note": "Event-based topic declares window parameters but the primary query has no event-time window predicate; confirm the extract actually applies the study window."})
    sid_joins = sourceid_join_details(text)
    if sid_joins:
        redundant = {t: ks for t, (ks, anc) in sid_joins.items() if anc}
        scoped = {t: ks for t, (ks, anc) in sid_joins.items() if not anc}
        if redundant:
            tables_plus_keys = ", ".join(f"{t} ({'+'.join(ks)})" if ks else t for t, ks in list(redundant.items())[:8])
            all_keys = sorted({k for ks in redundant.values() for k in ks})
            keys_txt = ", ".join(all_keys[:8]) if all_keys else "the entity record IDs"
            suggestions.append({"check": 4, "note": f"SourceID is used in join predicates on: {tables_plus_keys}. Drop SourceID from these join predicates — the joins are anchored on PatientID + VisitID (PI + VI) and explicit entity keys ({keys_txt}), so SourceID is redundant in the key; retain it only as a source attribute, not a join key."})
        if scoped:
            tables_plus_keys = ", ".join(f"{t} ({'+'.join(ks)})" if ks else t for t, ks in list(scoped.items())[:8])
            suggestions.append({"check": 4, "note": f"SourceID is the source-scoping key in joins to: {tables_plus_keys}. These entity IDs are per-source, so SourceID is load-bearing here and must be retained as part of the natural key — do not treat it as a redundant predicate."})
    return suggestions


def format_join_tables(join_map):
    return ", ".join(f"{t} ({'+'.join(ks)})" if ks else t for t, ks in list(join_map.items())[:8])


def default_review_note(check, *, text, event_based, model, grain, canonical_time,
                        detected_event_time, missing_sources, extra_sources,
                        planned_sources, sql_sources):
    if check == 1:
        if event_based:
            return f"Topic is reviewed as {model} with grain '{grain}'; static inspection did not detect a stronger grain or event-handling mismatch in the checked-in build."
        return f"Topic is reviewed as {model} with grain '{grain}'; no event-stream re-graining change is required for this contract."
    if check == 2:
        if detected_event_time:
            return f"Canonical time is documented as {canonical_time} and the output exposes {detected_event_time}; static inspection did not find a stronger event-time selection issue."
        if event_based:
            return f"Canonical time is documented as {canonical_time}; production execution should still confirm it is populated consistently for event rows."
        return f"This {model} contract does not rely on a single event stream, and no stronger event-time selection issue was detected in static review."
    if check == 3:
        if not text:
            return "No checked-in SQL was available for a completeness and window-boundary review."
        excl, incl, lower_only = window_bounds(text)
        has_window = bool(re.search(r"@WindowStart|@WindowEnd", text, re.I))
        if has_window and excl and not incl and not lower_only:
            return "Window logic uses an inclusive start and exclusive next-day upper bound; no obvious boundary defect was detected in static review."
        if has_window and not excl and not incl and not lower_only:
            return "Window parameters are declared, and static inspection did not surface a stronger completeness or boundary issue."
        return "Procedure appears to be an intentional full-history or full-refresh extract without a constrained date window."
    if check == 4:
        if not text:
            return "No checked-in SQL was available for a join and duplication review."
        sid_joins = sourceid_join_details(text)
        redundant = {t: ks for t, (ks, anc) in sid_joins.items() if anc}
        scoped = {t: ks for t, (ks, anc) in sid_joins.items() if not anc}
        if scoped and not redundant:
            return f"SourceID is retained only on source-scoped joins ({format_join_tables(scoped)}); no redundant PI/VI-anchored SourceID join was detected."
        if not sid_joins:
            return "No obvious redundant SourceID join or uncontrolled join fan-out was detected in static review."
        return "Join review did not surface an additional issue beyond the flagged SourceID or duplication findings."
    if check == 5:
        if missing_sources and extra_sources:
            return f"Topic source contract is only partially covered: SQL does not read {', '.join(missing_sources)}, and it also depends on supporting sources not listed in the contract ({', '.join(extra_sources)})."
        if missing_sources:
            return f"Topic source contract is not fully covered by the primary SQL; missing reads: {', '.join(missing_sources)}."
        if extra_sources:
            return f"Primary SQL covers the curated contract and also uses supporting sources not listed in it: {', '.join(extra_sources)}."
        if planned_sources and sql_sources:
            return "Primary SQL reads align with the curated topic source contract."
        return "Topic source coverage could not be fully confirmed from the checked-in contract and SQL metadata."
    return "No additional review note was generated."


def audit_asset(asset, tables):
    path = os.path.join(SQL_DIR, asset["file"])
    text = io.open(path, encoding="utf-8-sig", errors="replace").read()
    declaration, proc_name, params = proc_header(text)
    author_match = re.search(r"Author\s*:?\s*([^\r\n*]+)", text, re.I)
    author = author_match.group(1).strip().rstrip("*/ ") if author_match else None
    flags = {
        "declaration": declaration, "author": author,
        "procedure": proc_name,
        "parameters": params,
        "try_catch": bool(re.search(r"\bBEGIN\s+TRY\b", text, re.I)),
        "xact_abort": bool(re.search(r"SET\s+XACT_ABORT\s+ON", text, re.I)),
        "transaction": bool(re.search(r"\bBEGIN\s+TRAN", text, re.I)),
        "run_logging": bool(re.search(r"Cohort_Log|BuildLog|RunLog", text, re.I)),
        "drop_publish": bool(re.search(r"DROP\s+TABLE", text, re.I)),
        "nolock_count": len(re.findall(r"\bNOLOCK\b", text, re.I)),
        "row_number": bool(re.search(r"ROW_NUMBER\s*\(", text, re.I)),
        "index_count": len(re.findall(r"CREATE\s+(?:UNIQUE\s+)?(?:NONCLUSTERED\s+|CLUSTERED\s+)?INDEX", text, re.I)),
        "sql_sources": sql_sources(text, tables),
    }
    findings = []
    if asset["kind"] == "build":
        if declaration == "alter":
            findings.append("ALTER PROCEDURE requires the procedure to exist; prefer CREATE OR ALTER for repeatable deployment.")
        if not flags["try_catch"]:
            findings.append("No TRY/CATCH boundary was detected.")
        if not flags["xact_abort"]:
            findings.append("XACT_ABORT is not enabled.")
        if not flags["transaction"]:
            findings.append("No explicit transaction protects publication.")
        if flags["drop_publish"]:
            findings.append("DROP/CREATE publication is non-atomic for concurrent readers.")
        if not params:
            findings.append("No formal window or watermark parameter was detected; this is a full rebuild contract.")
        if not flags["run_logging"]:
            findings.append("No run-log write was detected.")
        if flags["nolock_count"]:
            findings.append("NOLOCK may return dirty, missing, or duplicated rows.")
        if not flags["index_count"]:
            findings.append("No explicit output index was detected.")
    flags["findings"] = findings
    return flags


def col_names(table):
    return [col.get("n") for col in (table or {}).get("cols", []) if isinstance(col, dict)]


def is_time_like_column(name):
    parts = re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+", name or "")
    joined = "".join(parts).lower()
    if joined.endswith("datetime") or joined.endswith("timestamp"):
        return True
    return bool(parts) and parts[-1].lower() in {"date", "time"}


def validation_query(topic, table, planned_tables, schema_tables, event_based, desired_time, status):
    output = table.get("output")
    out_table = schema_tables.get(output, {})
    cols = col_names(out_table)
    if cols:
        metrics = ["COUNT(*) AS Rows"]
        if "PatientID" in cols:
            metrics.append("COUNT(DISTINCT PatientID) AS Patients")
        if "VisitID" in cols:
            metrics.append("COUNT(DISTINCT VisitID) AS Visits")
        time_cols = [name for name in cols if is_time_like_column(name) and name.lower() not in {"extractedon", "rowupdatedatetime"}]
        event_col = next((name for name in time_cols if name.lower() == desired_time.lower()), time_cols[0] if time_cols else None)
        if event_col:
            metrics.extend([f"SUM(CASE WHEN [{event_col}] IS NULL THEN 1 ELSE 0 END) AS MissingEventTime", f"MIN([{event_col}]) AS FirstEvent", f"MAX([{event_col}]) AS LastEvent"])
        lines = [f"-- Output health: {topic['name']}", "SELECT " + ",\n       ".join(metrics), f"FROM [CDIO_MeditechDB].[dbo].[{output}];"]
        pk = [key for key in out_table.get("pk", []) if key in cols]
        if pk:
            keys = ", ".join("[" + key + "]" for key in pk)
            lines.extend(["", "-- Duplicate output keys: expect zero rows", f"SELECT {keys}, COUNT(*) AS DuplicateRows", f"FROM [CDIO_MeditechDB].[dbo].[{output}]", f"GROUP BY {keys}", "HAVING COUNT(*) > 1;"])
        if event_based and not event_col:
            lines.extend(["", f"-- GAP: add the canonical event field [{desired_time}] before event-time validation."])
        return "\n".join(lines), event_col, time_cols, "output-validation"
    if planned_tables:
        lines = [f"-- Source readiness: {topic['name']}"]
        selects = []
        for name in planned_tables:
            db = schema_tables.get(name, {}).get("db", "AKULiveATdb")
            selects.append(f"SELECT '{name}' AS SourceTable, COUNT(*) AS Rows FROM [{db}].[dbo].[{name}]")
        lines.append("\nUNION ALL\n".join(selects) + ";")
        lines.extend(["", f"-- Proposed output: [CDIO_MeditechDB].[dbo].[{output}]", f"-- Required canonical time: [{desired_time}]" if event_based else "-- Snapshot/reference contract: no event stream required."])
        return "\n".join(lines), None, [], "source-readiness"
    terms = DISCOVERY_TERMS.get(topic["id"], [topic["name"].split()[0]])
    predicates = []
    for term in terms:
        safe = term.replace("'", "''")
        predicates.extend([f"TABLE_NAME LIKE '%{safe}%'", f"COLUMN_NAME LIKE '%{safe}%'"])
    lines = [f"-- Source discovery gate: {topic['name']}", "SELECT TABLE_SCHEMA, TABLE_NAME, COUNT(*) AS MatchingColumns", "FROM [AKULiveATdb].INFORMATION_SCHEMA.COLUMNS", "WHERE " + " OR ".join(predicates), "GROUP BY TABLE_SCHEMA, TABLE_NAME", "ORDER BY MatchingColumns DESC, TABLE_NAME;"]
    return "\n".join(lines), None, [], "source-discovery"


def main():
    schema = load_js(SCHEMA)
    phases = load_js(PHASES)
    tables = schema["tables"]
    assets = {asset["id"]: dict(asset) for asset in schema.get("procedures", [])}
    asset_audits = {asset_id: audit_asset(asset, tables) for asset_id, asset in assets.items()}

    phase_topics = []
    for phase in phases["phases"]:
        for topic in phase["topics"]:
            phase_topics.append((phase, topic))
    missing_models = sorted(topic["id"] for _, topic in phase_topics if topic["id"] not in MODEL)
    if missing_models:
        raise SystemExit("Missing event models: " + ", ".join(missing_models))

    sp_use = collections.defaultdict(list)
    for _, topic in phase_topics:
        if topic.get("sp"):
            sp_use[topic["sp"]["name"]].append(topic["id"])

    reviews = []
    missing_source_topics = 0
    missing_source_refs = 0
    primary_asset_ids = set()
    for phase, topic in phase_topics:
        event_based, model, grain, event_time, rationale = MODEL[topic["id"]]
        existing = topic.get("sp")
        if existing:
            suffix = existing["name"]
            procedure = "usp_Build_" + suffix
            output = existing["out"]
            if existing["status"] == "blueprint":
                status = "blueprint"
            elif topic["id"] in SHARED_TOPIC_IDS:
                status = "shared"
            else:
                status = "implemented"
        else:
            suffix = PROPOSED[topic["id"]]
            procedure = "usp_Build_" + suffix
            output = "tbl_" + suffix
            status = "source-gap"

        asset = assets.get(procedure)
        audit = asset_audits.get(procedure)
        if audit:
            primary_asset_ids.add(procedure)
        sql_read = audit["sql_sources"] if audit else []
        planned = list(topic.get("tables", []))
        missing_sources = sorted(set(planned) - set(sql_read)) if audit else []
        extra_sources = sorted(set(sql_read) - set(planned)) if audit else []
        if missing_sources:
            missing_source_topics += 1
            missing_source_refs += len(missing_sources)

        evidence_tier, evidence_note = EVIDENCE.get(topic["id"], ("implemented-build", "Checked-in FCAP1A build procedure"))
        table_context = {"output": output}
        query, detected_event_time, output_time_cols, query_kind = validation_query(topic, table_context, planned, tables, event_based, event_time, status)
        findings, recommendations = [], []
        if evidence_tier == "generic-relational":
            findings.append(evidence_note + ".")
            recommendations.append("Validate topic-filter sensitivity and specificity against the owning clinical system before acceptance.")
        elif evidence_tier == "external-metadata":
            findings.append(evidence_note + ".")
            recommendations.append("Onboard authoritative external identifiers, consent, retention, and access controls.")
        elif evidence_tier == "direct-partial":
            findings.append(evidence_note + ".")
            recommendations.append("Confirm and add the missing structured event field before clinical acceptance.")
        if status == "source-gap":
            findings.append("No curated domain source contract or implemented build exists.")
            recommendations.extend(["Confirm the owning clinical system and land the domain tables.", "Define patient, encounter, consent, retention, and event-time linkage before implementation."])
        elif status == "blueprint":
            findings.append("The topic has a curated source contract but no checked-in primary procedure.")
            recommendations.append("Implement, review, and deploy the proposed primary build procedure.")
        elif status == "shared":
            findings.append("This topic reuses a procedure owned by another data topic; it has no dedicated output contract.")
            recommendations.append("Create a dedicated output or a documented semantic view with topic-specific tests.")
        if missing_sources:
            findings.append(f"The topic contract lists {len(missing_sources)} source table(s) not read by the primary SQL.")
            recommendations.append("Reconcile planned-vs-SQL source coverage before accepting the procedure as complete.")
        if extra_sources:
            findings.append(f"The primary SQL reads {len(extra_sources)} supporting table(s) not listed in the topic contract.")
        if audit:
            findings.extend(audit["findings"])
            recommendations.extend([
                "Reconcile planned-vs-SQL source coverage before accepting the procedure as complete.",
                "Build into a staging table and publish with a short transactional swap.",
                "Add window/watermark parameters and an incremental execution path.",
                "Define output indexes for patient, visit, event time, and the natural record key.",
            ])
            if audit["declaration"] == "alter":
                recommendations.append("Change ALTER PROCEDURE to CREATE OR ALTER for repeatable deployment.")
            if not audit["try_catch"]:
                recommendations.append("Add TRY/CATCH, XACT_ABORT, failure logging, and THROW.")
        if event_based and not detected_event_time and output in tables:
            findings.append(f"The output has no detected canonical [{event_time}] event field.")
            recommendations.append(f"Expose a canonical {event_time} and retain source-specific timestamps separately.")

        suggestions = []
        if audit:
            sql_text = load_sql_text(asset)
            curated = CURATED_SUGGESTIONS.get(procedure, [])
            suggestions.extend(curated)
            for s in sql_review_suggestions(procedure, sql_text, event_based, event_time):
                if any(e.get("check") == s["check"] for e in curated):
                    continue
                s_tokens = {w for w in s["note"].split() if len(w) > 3 and w not in ("predicate", "window", "the", "that", "with", "from", "this", "and", "for")}
                if any(s_tokens and len(s_tokens & {w for w in e["note"].split() if len(w) > 3 and w not in ("predicate", "window", "the", "that", "with", "from", "this", "and", "for")}) >= 0.6 * max(len(s_tokens), 1) for e in suggestions):
                    continue
                suggestions.append(s)

        recommendations = list(dict.fromkeys(recommendations))
        if status in {"source-gap", "blueprint"} or (audit and not audit["try_catch"]) or len(missing_sources) >= 3:
            priority = "high"
        elif evidence_tier in {"generic-relational", "external-metadata", "direct-partial"} or status == "shared" or missing_sources or (audit and audit["drop_publish"]):
            priority = "medium"
        else:
            priority = "low"
        review_checks = []
        grouped_suggestions = collections.defaultdict(list)
        for entry in suggestions:
            grouped_suggestions[entry["check"]].append(entry["note"])
        for check in sorted(CHECKS):
            if grouped_suggestions[check]:
                note = " ".join(grouped_suggestions[check])
                kind = "issue"
            else:
                note = default_review_note(
                    check,
                    text=sql_text if audit else "",
                    event_based=event_based,
                    model=model,
                    grain=grain,
                    canonical_time=event_time,
                    detected_event_time=detected_event_time,
                    missing_sources=missing_sources,
                    extra_sources=extra_sources,
                    planned_sources=planned,
                    sql_sources=sql_read,
                )
                kind = "pass"
            review_checks.append({
                "check": check,
                "label": CHECKS[check],
                "kind": kind,
                "note": note,
            })

        improved_sp = []
        if recommendations:
            improved_sp = recommendations[:]
        elif findings:
            improved_sp = findings[:]
        else:
            improved_sp = ["Maintain the current stored procedure contract and rerun the regression checks after source or schema changes."]

        reviews.append({
            "id": topic["id"], "name": topic["name"], "phase": phase["name"], "phase_id": phase["id"],
            "category": topic["cat"], "availability": topic["avail"], "description": topic["desc"],
            "procedure": procedure, "output": output, "status": status, "priority": priority,
            "event_based": event_based, "event_model": model, "grain": grain,
            "canonical_time": event_time, "detected_event_time": detected_event_time,
            "output_time_columns": output_time_cols, "event_rationale": rationale,
            "planned_sources": planned, "sql_sources": sql_read,
            "missing_sources": missing_sources, "extra_sources": extra_sources,
            "asset": procedure if audit else None, "author": audit.get("author") if audit else None,
            "evidence_tier": evidence_tier, "evidence_note": evidence_note, "findings": findings,
            "recommendations": recommendations, "suggestions": suggestions, "review_checks": review_checks, "improved_sp": improved_sp,
            "query": query, "query_kind": query_kind,
        })

    status_counts = collections.Counter(review["status"] for review in reviews)
    event_counts = collections.Counter("event-based" if review["event_based"] else "not-event-based" for review in reviews)
    primary_audits = [asset_audits[asset_id] for asset_id in sorted(primary_asset_ids)]
    summary = {
        "topics": len(reviews), "status": dict(sorted(status_counts.items())), "event": dict(sorted(event_counts.items())),
        "sql_assets": len(assets), "primary_implemented_procedures": len(primary_audits),
        "planned_source_gap_topics": missing_source_topics, "planned_source_gap_references": missing_source_refs,
        "alter_only_primary": sum(a["declaration"] == "alter" for a in primary_audits),
        "drop_publish_primary": sum(a["drop_publish"] for a in primary_audits),
        "try_catch_primary": sum(a["try_catch"] for a in primary_audits),
        "xact_abort_primary": sum(a["xact_abort"] for a in primary_audits),
        "transaction_primary": sum(a["transaction"] for a in primary_audits),
        "parameterized_primary": sum(bool(a["parameters"]) for a in primary_audits),
        "indexed_primary": sum(a["index_count"] > 0 for a in primary_audits),
        "topics_with_suggestions": sum(1 for r in reviews if r["suggestions"]),
        "suggestion_count": sum(len(r["suggestions"]) for r in reviews),
    }
    priorities = [
        {"priority": "medium", "title": "Apply SP review suggestions", "detail": f"{summary['topics_with_suggestions']} of {len(reviews)} implemented topics have {summary['suggestion_count']} actionable review suggestions across the four review checks (event handling, event-date selection, completeness, join correctness / SourceID removal)."}] + [
        {"priority": "high" if status_counts["source-gap"] + status_counts["blueprint"] else "low", "title": "Dedicated procedure coverage", "detail": f"{len(reviews) - status_counts['source-gap'] - status_counts['blueprint']} of {len(reviews)} topics now have checked-in procedures; partial and external evidence tiers remain clearly labelled."},
        {"priority": "high", "title": "Reconcile source-to-SQL coverage", "detail": f"{missing_source_topics} implemented/shared topics list {missing_source_refs} planned source references that their primary SQL does not read."},
        {"priority": "high", "title": "Make publication atomic", "detail": f"All {summary['drop_publish_primary']} implemented primary procedures use DROP/CREATE publication; use staged tables plus a short transactional swap."},
        {"priority": "high", "title": "Harden failure semantics", "detail": f"{summary['try_catch_primary']} of {len(primary_audits)} primary procedures have TRY/CATCH, but only {summary['xact_abort_primary']} enables XACT_ABORT and {summary['transaction_primary']} uses an explicit transaction."},
        {"priority": "medium", "title": "Standardise repeatable deployment", "detail": f"{summary['alter_only_primary']} primary procedures are ALTER-only and fail on a clean environment; normalise on CREATE OR ALTER."},
        {"priority": "medium", "title": "Add incremental execution contracts", "detail": f"Only {summary['parameterized_primary']} of {len(primary_audits)} primary procedures exposes formal parameters; add date windows or watermarks without changing clinical-event semantics."},
        {"priority": "medium", "title": "Define physical output contracts", "detail": f"Only {summary['indexed_primary']} of {len(primary_audits)} primary procedures creates output indexes; define patient, visit, event-time, and natural-key indexes by grain."},
    ]
    payload = {
        "meta": {"generated": dt.date.today().isoformat(), "method": "Static review of checked-in SQL plus curated topic and schema contracts."},
        "summary": summary, "priorities": priorities, "topics": reviews, "assets": asset_audits,
    }
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("window.SP_REVIEW = ")
        handle.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        handle.write(";\n")
    print("wrote", OUT)
    print("topics", len(reviews), "status", dict(sorted(status_counts.items())))
    print("assets", len(assets), "primary", len(primary_audits), "planned source gaps", missing_source_topics, missing_source_refs)


if __name__ == "__main__":
    main()
