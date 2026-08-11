/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Medications_Extended]    Script Date: 7/13/2026 1:22:58 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure : dbo.usp_Build_FCAP1A_Medications_Extended
    Version          : Extended
    Author           : Allan Z.
    Development Date : 2026-02-19
	Revision : 2026-06-14

    Purpose:
        Builds the FCAP 1A Medications dataset (Extended scope) as an event-level medication timeline
        (orders, medication detail, administrations, and scan events) restricted to the Extended FCAP cohort.

    Notes:
        Execute this script as a single batch. Do not insert GO statements inside the procedure body.
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Medications_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunStart        DATETIME = SYSDATETIME();
    DECLARE @RunEnd          DATETIME;
    DECLARE @DurationSeconds INT;
    DECLARE @RecordCount     INT = 0;
    DECLARE @TotalEligible   INT = 0;

    DECLARE @WindowStart      DATE = '2022-11-05';
    DECLARE @WindowEnd        DATE = '2026-06-14';
    DECLARE @WindowEndNextDay DATE = DATEADD(DAY, 1, @WindowEnd);

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME        NOT NULL,
            RunEnd          DATETIME        NULL,
            DurationSeconds INT             NULL,
            RunStatus       VARCHAR(20)     NOT NULL,
            DataTopic       NVARCHAR(100)   NOT NULL,
            WindowStart     DATE            NULL,
            WindowEnd       DATE            NULL,
            TotalEligible   INT             NULL,
            RecordCount     INT             NULL,
            ProcessedBy     NVARCHAR(100)   NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000)  NULL,
            Remarks         NVARCHAR(4000)  NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_Medications_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Medications_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Medications_Extended (
        MedicationRowID        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,

        PatientID              NVARCHAR(50)      NOT NULL,
        VisitID                NVARCHAR(50)      NULL,

        DrugID                 NVARCHAR(255)     NULL,
        PrescriptionID         NVARCHAR(255)     NOT NULL,
        MedicationName         NVARCHAR(255)     NULL,

        GenericClassID         NVARCHAR(255)     NULL,
        GenericName            NVARCHAR(255)     NULL,
        NdcDinNumber           NVARCHAR(255)     NULL,
        ControlScheduleID      NVARCHAR(255)     NULL,

        OrderDateTime          DATETIME          NULL,
        AdministrationDateTime DATETIME          NULL,
        DiscontinueDateTime    DATETIME          NULL,
        EventDateTime          DATETIME          NOT NULL,

        Route                  NVARCHAR(255)     NULL,
        DoseAmount             NVARCHAR(255)     NULL,
        DoseUnit               NVARCHAR(255)     NULL,
        Frequency              NVARCHAR(255)     NULL,
        Form                   NVARCHAR(255)     NULL,

        MedicationStatus       NVARCHAR(255)     NULL,
        PRNFlag                NVARCHAR(10)      NULL,

        OrderingProviderID     NVARCHAR(255)     NULL,
        AdministeringUserID    NVARCHAR(255)     NULL,
        AdministrationSeqID    NVARCHAR(50)      NULL,

        SourceTable            NVARCHAR(100)     NOT NULL,
        RowUpdateDateTime      DATETIME          NULL
    );

    BEGIN TRY

        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        IF OBJECT_ID('tempdb..#CohortVisits') IS NOT NULL DROP TABLE #CohortVisits;

        SELECT DISTINCT
            c.PatientID,
            v.VisitID
        INTO #CohortVisits
        FROM dbo.tbl_FCAP1A_Cohort10_Extended AS c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
               = v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS;

        IF OBJECT_ID('tempdb..#Rx') IS NOT NULL DROP TABLE #Rx;

        SELECT
            cv.PatientID,
            r.VisitID,
            r.SourceID,
            r.PrescriptionID,
            r.ProviderID,
            r.RouteOfAdministration,
            r.Schedule,
            r.Status,
            r.StartDateTime,
            r.EnterDateTime,
            r.DiscontinueDateTime,
            r.RangeDoseLow,
            r.RowUpdateDateTime
        INTO #Rx
        FROM [NBIDRSRV2].[AKULivendb].dbo.PhaRx AS r
        INNER JOIN #CohortVisits AS cv
            ON cv.VisitID = r.VisitID
        WHERE COALESCE(r.StartDateTime, r.EnterDateTime, r.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(r.StartDateTime, r.EnterDateTime, r.RowUpdateDateTime) <  @WindowEndNextDay;

        IF OBJECT_ID('tempdb..#Med') IS NOT NULL DROP TABLE #Med;

        SELECT
            rx.PatientID,
            rx.VisitID,
            m.SourceID,
            m.PrescriptionID,
            m.DrugID,
            m.Dose,
            m.TotalDoseUnits,
            m.PrnLevel,
            m.OutWrittenDateTime,
            m.RowUpdateDateTime
        INTO #Med
        FROM [NBIDRSRV2].[AKULivendb].dbo.PhaRxMedications AS m
        INNER JOIN #Rx AS rx
            ON m.SourceID       = rx.SourceID
           AND m.PrescriptionID = rx.PrescriptionID
        WHERE COALESCE(m.OutWrittenDateTime, m.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(m.OutWrittenDateTime, m.RowUpdateDateTime) <  @WindowEndNextDay;

        IF OBJECT_ID('tempdb..#MedKey') IS NOT NULL DROP TABLE #MedKey;

        ;WITH MedKeyCTE AS (
            SELECT
                m.SourceID,
                m.PrescriptionID,
                m.DrugID,
                m.TotalDoseUnits,
                m.PrnLevel,
                m.Dose,
                m.RowUpdateDateTime,
                ROW_NUMBER() OVER (
                    PARTITION BY m.SourceID, m.PrescriptionID
                    ORDER BY m.RowUpdateDateTime DESC
                ) AS rn
            FROM #Med AS m
        )
        SELECT
            SourceID,
            PrescriptionID,
            DrugID,
            TotalDoseUnits,
            PrnLevel,
            Dose
        INTO #MedKey
        FROM MedKeyCTE
        WHERE rn = 1;

        IF OBJECT_ID('tempdb..#Admin') IS NOT NULL DROP TABLE #Admin;

        SELECT
            rx.PatientID,
            rx.VisitID,
            a.SourceID,
            a.PrescriptionID,
            a.AdministrationSeqID,
            a.AdministrationDateTime,
            a.AdministrationUserID,
            a.DoseAdministered,
            a.EntryDateTime,
            a.RowUpdateDateTime
        INTO #Admin
        FROM [NBIDRSRV2].[AKULivendb].dbo.PhaRxAdministrations AS a
        INNER JOIN #Rx AS rx
            ON a.SourceID       = rx.SourceID
           AND a.PrescriptionID = rx.PrescriptionID
        WHERE COALESCE(a.AdministrationDateTime, a.EntryDateTime, a.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(a.AdministrationDateTime, a.EntryDateTime, a.RowUpdateDateTime) <  @WindowEndNextDay;

        IF OBJECT_ID('tempdb..#Scan') IS NOT NULL DROP TABLE #Scan;

        SELECT
            cv.PatientID,
            s.VisitID,
            s.SourceID,
            s.PrescriptionID,
            s.DrugID,
            s.UserID,
            s.ScanDateTime,
            s.RowUpdateDateTime
        INTO #Scan
        FROM [NBIDRSRV2].[AKULivendb].dbo.PhaRxScannedMedPatientX AS s
        INNER JOIN #CohortVisits AS cv
            ON cv.VisitID = s.VisitID
        WHERE COALESCE(s.ScanDateTime, s.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(s.ScanDateTime, s.RowUpdateDateTime) <  @WindowEndNextDay;

        IF OBJECT_ID('tempdb..#AllEvents') IS NOT NULL DROP TABLE #AllEvents;

        ;WITH RxEvents AS (
            SELECT
                rx.PatientID,
                rx.VisitID,
                mk.DrugID,
                rx.PrescriptionID,
                rx.StartDateTime                         AS OrderDateTime,
                CAST(NULL AS DATETIME)                   AS AdministrationDateTime,
                rx.DiscontinueDateTime                   AS DiscontinueDateTime,
                COALESCE(rx.StartDateTime, rx.EnterDateTime, rx.RowUpdateDateTime)
                                                        AS EventDateTime,
                rx.RouteOfAdministration                 AS Route,
                COALESCE(mk.Dose, CAST(rx.RangeDoseLow AS NVARCHAR(255)))
                                                        AS DoseAmount,
                mk.TotalDoseUnits                        AS DoseUnit,
                rx.Schedule                              AS Frequency,
                rx.Status                                AS MedicationStatus,
                CASE
                    WHEN mk.PrnLevel IS NULL THEN NULL
                    WHEN mk.PrnLevel <> 0 THEN N'Y'
                    ELSE N'N'
                END                                      AS PRNFlag,
                rx.ProviderID                            AS OrderingProviderID,
                CAST(NULL AS NVARCHAR(255))              AS AdministeringUserID,
                NULL                                     AS AdministrationSeqID,
                N'PhaRx'                                 AS SourceTable,
                rx.SourceID,
                rx.RowUpdateDateTime                     AS RowUpdateDateTime
            FROM #Rx AS rx
            LEFT JOIN #MedKey AS mk
                ON rx.SourceID       = mk.SourceID
               AND rx.PrescriptionID = mk.PrescriptionID
        ),
        AdminEvents AS (
            SELECT
                a.PatientID,
                a.VisitID,
                mk.DrugID,
                a.PrescriptionID,
                rx.StartDateTime                         AS OrderDateTime,
                a.AdministrationDateTime                 AS AdministrationDateTime,
                rx.DiscontinueDateTime                   AS DiscontinueDateTime,
                COALESCE(a.AdministrationDateTime, a.EntryDateTime, a.RowUpdateDateTime)
                                                        AS EventDateTime,
                rx.RouteOfAdministration                 AS Route,
                a.DoseAdministered                       AS DoseAmount,
                mk.TotalDoseUnits                        AS DoseUnit,
                rx.Schedule                              AS Frequency,
                rx.Status                                AS MedicationStatus,
                CASE
                    WHEN mk.PrnLevel IS NULL THEN NULL
                    WHEN mk.PrnLevel <> 0 THEN N'Y'
                    ELSE N'N'
                END                                      AS PRNFlag,
                rx.ProviderID                            AS OrderingProviderID,
                a.AdministrationUserID                   AS AdministeringUserID,
                a.AdministrationSeqID                    AS AdministrationSeqID,
                N'PhaRxAdministrations'                  AS SourceTable,
                a.SourceID,
                COALESCE(a.RowUpdateDateTime, rx.RowUpdateDateTime)
                                                        AS RowUpdateDateTime
            FROM #Admin AS a
            INNER JOIN #Rx AS rx
                ON a.SourceID       = rx.SourceID
               AND a.PrescriptionID = rx.PrescriptionID
            LEFT JOIN #MedKey AS mk
                ON a.SourceID       = mk.SourceID
               AND a.PrescriptionID = mk.PrescriptionID
        ),
        MedEvents AS (
            SELECT
                m.PatientID,
                m.VisitID,
                m.DrugID,
                m.PrescriptionID,
                rx.StartDateTime                         AS OrderDateTime,
                CAST(NULL AS DATETIME)                   AS AdministrationDateTime,
                rx.DiscontinueDateTime                   AS DiscontinueDateTime,
                COALESCE(m.OutWrittenDateTime, m.RowUpdateDateTime)
                                                        AS EventDateTime,
                rx.RouteOfAdministration                 AS Route,
                m.Dose                                   AS DoseAmount,
                m.TotalDoseUnits                         AS DoseUnit,
                rx.Schedule                              AS Frequency,
                rx.Status                                AS MedicationStatus,
                CASE
                    WHEN m.PrnLevel IS NULL THEN NULL
                    WHEN m.PrnLevel <> 0 THEN N'Y'
                    ELSE N'N'
                END                                      AS PRNFlag,
                rx.ProviderID                            AS OrderingProviderID,
                CAST(NULL AS NVARCHAR(255))              AS AdministeringUserID,
                NULL                                     AS AdministrationSeqID,
                N'PhaRxMedications'                      AS SourceTable,
                m.SourceID,
                m.RowUpdateDateTime                      AS RowUpdateDateTime
            FROM #Med AS m
            INNER JOIN #Rx AS rx
                ON m.SourceID       = rx.SourceID
               AND m.PrescriptionID = rx.PrescriptionID
        ),
        ScanEvents AS (
            SELECT
                s.PatientID,
                s.VisitID,
                COALESCE(mk.DrugID, s.DrugID)            AS DrugID,
                s.PrescriptionID,
                rx.StartDateTime                         AS OrderDateTime,
                CAST(NULL AS DATETIME)                   AS AdministrationDateTime,
                rx.DiscontinueDateTime                   AS DiscontinueDateTime,
                COALESCE(s.ScanDateTime, s.RowUpdateDateTime)
                                                        AS EventDateTime,
                rx.RouteOfAdministration                 AS Route,
                CAST(NULL AS NVARCHAR(255))              AS DoseAmount,
                mk.TotalDoseUnits                        AS DoseUnit,
                rx.Schedule                              AS Frequency,
                rx.Status                                AS MedicationStatus,
                CASE
                    WHEN mk.PrnLevel IS NULL THEN NULL
                    WHEN mk.PrnLevel <> 0 THEN N'Y'
                    ELSE N'N'
                END                                      AS PRNFlag,
                rx.ProviderID                            AS OrderingProviderID,
                s.UserID                                 AS AdministeringUserID,
                NULL                                     AS AdministrationSeqID,
                N'PhaRxScannedMedPatientX'               AS SourceTable,
                s.SourceID,
                s.RowUpdateDateTime                      AS RowUpdateDateTime
            FROM #Scan AS s
            LEFT JOIN #Rx AS rx
                ON s.SourceID       = rx.SourceID
               AND s.PrescriptionID = rx.PrescriptionID
            LEFT JOIN #MedKey AS mk
                ON s.SourceID       = mk.SourceID
               AND s.PrescriptionID = mk.PrescriptionID
        )
        SELECT
            PatientID,
            VisitID,
            DrugID,
            PrescriptionID,
            OrderDateTime,
            AdministrationDateTime,
            DiscontinueDateTime,
            EventDateTime,
            Route,
            DoseAmount,
            DoseUnit,
            Frequency,
            MedicationStatus,
            PRNFlag,
            OrderingProviderID,
            AdministeringUserID,
            AdministrationSeqID,
            SourceTable,
            RowUpdateDateTime,
            SourceID
        INTO #AllEvents
        FROM (
            SELECT * FROM RxEvents
            UNION ALL
            SELECT * FROM AdminEvents
            UNION ALL
            SELECT * FROM MedEvents
            UNION ALL
            SELECT * FROM ScanEvents
        ) AS X;

        INSERT INTO dbo.tbl_FCAP1A_Medications_Extended (
            PatientID,
            VisitID,
            DrugID,
            PrescriptionID,
            MedicationName,
            GenericClassID,
            GenericName,
            NdcDinNumber,
            ControlScheduleID,
            OrderDateTime,
            AdministrationDateTime,
            DiscontinueDateTime,
            EventDateTime,
            Route,
            DoseAmount,
            DoseUnit,
            Frequency,
            Form,
            MedicationStatus,
            PRNFlag,
            OrderingProviderID,
            AdministeringUserID,
            AdministrationSeqID,
            SourceTable,
            RowUpdateDateTime
        )
        SELECT
            e.PatientID,
            e.VisitID,
            e.DrugID,
            e.PrescriptionID,
            d.Name                              AS MedicationName,
            g.GenericClassID                    AS GenericClassID,
            g.Name                              AS GenericName,
            d.NdcDinNumber                      AS NdcDinNumber,
            d.ControlScheduleID                 AS ControlScheduleID,
            e.OrderDateTime,
            e.AdministrationDateTime,
            e.DiscontinueDateTime,
            e.EventDateTime,
            e.Route,
            e.DoseAmount,
            e.DoseUnit,
            e.Frequency,
            d.AdminFormID                       AS Form,
            e.MedicationStatus,
            e.PRNFlag,
            e.OrderingProviderID,
            e.AdministeringUserID,
            e.AdministrationSeqID,
            e.SourceTable,
            COALESCE(e.RowUpdateDateTime, d.RowUpdateDateTime, g.RowUpdateDateTime)
                                                AS RowUpdateDateTime
        FROM #AllEvents AS e
        LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.DPhaDrugData AS d
            ON e.SourceID = d.SourceID
           AND e.DrugID   = d.DrugID
        LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.DPhaGeneric AS g
            ON d.SourceID     = g.SourceID
           AND d.GenericID    = g.GenericClassID;

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_Medications_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'Medications_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            NULL,
            N'Medication events from PhaRx, PhaRxMedications, PhaRxAdministrations, PhaRxScannedMedPatientX with dictionary enrichment.'
        );

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            N'Medications_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @Err,
            N'Error during Medications rebuild.'
        );

        THROW;
    END CATCH
END
