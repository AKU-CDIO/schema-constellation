USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Encounters_Extended]    Script Date: 7/13/2026 1:00:45 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure: usp_Build_FCAP1A_Encounters_Extended

    Purpose:
        Build the FCAP 1A Encounter dataset using RegAcct_Main as the universal
        encounter anchor and AdmVisits as the enrichment source.

        Encounters remain purely administrative (visit-level only).
        No demographics, no billing, no clinical content.

    Sources:
        [NBIDRSRV2].[AKULiveATdb].dbo.RegAcct_Main   -- primary
        [NBIDRSRV2].[AKULivendb].dbo.AdmVisits       -- enrichment
        dbo.tbl_FCAP1A_Cohort10_Extended            -- FCAP Extended cohort

    Notes:
        - Discharge time is not directly available in AdmVisits, so we leave EndDateTime NULL.
        - EncounterClass is taken from AdmVisits.InpatientOrOutpatient.
        - EncounterType comes from RegAcct_Main.RegistrationType_MisRegTypeID.
        - StartDateTime is derived using a clinical-friendly priority.
        - Authorship intentionally documented for future reviewers.

    Version: Extended
    Development Date: 2026-02-19
	Revised Date : 2026-07-13 (Matched with ISERC Request)
    Created by: Allan Z.
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Encounters_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart          DATETIME = SYSDATETIME(),
        @RunEnd            DATETIME,
        @DurationSeconds   INT,
        @RecordCount       INT = 0,
        @WindowStart       DATE = '2022-11-05',
        @WindowEnd         DATE = '2026-06-14',
        @WindowEndNextDay  DATE;

    SET @WindowEndNextDay = DATEADD(DAY, 1, @WindowEnd);

    -----------------------------------------------------------------------
    -- Ensure FCAP log table exists
    -----------------------------------------------------------------------
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log
        (
            LogID            INT IDENTITY(1,1) PRIMARY KEY,
            RunStart         DATETIME NOT NULL,
            RunEnd           DATETIME NULL,
            DurationSeconds  INT NULL,
            RunStatus        VARCHAR(20) NOT NULL,
            DataTopic        NVARCHAR(100) NOT NULL,
            WindowStart      DATE NULL,
            WindowEnd        DATE NULL,
            TotalEligible    INT NULL,
            RecordCount      INT NULL,
            ProcessedBy      NVARCHAR(100) NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage     NVARCHAR(4000) NULL,
            Remarks          NVARCHAR(4000) NULL
        );
    END;

    -----------------------------------------------------------------------
    -- Rebuild target table
    -----------------------------------------------------------------------
    IF OBJECT_ID('dbo.tbl_FCAP1A_Encounters_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Encounters_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Encounters_Extended
    (
        EncounterRowID       INT IDENTITY(1,1) PRIMARY KEY,

        PatientID            NVARCHAR(255) NOT NULL,
        VisitID              NVARCHAR(255) NOT NULL,
        SourceID             NVARCHAR(50)  NOT NULL,

        EncounterClass       NVARCHAR(100) NULL,
        EncounterType        NVARCHAR(100) NULL,
        RegistrationStatus   NVARCHAR(100) NULL,
        VisitStatus          NVARCHAR(100) NULL,

        StartDateTime        DATETIME NULL,
        EndDateTime          DATETIME NULL,     -- left NULL unless a discharge source is added
        AdmitDateTime        DATETIME NULL,
        ArrivalDateTime      DATETIME NULL,
        ServiceDateTime      DATETIME NULL,
        DischargeDateTime    DATETIME NULL,     -- left NULL intentionally
        RowUpdateDateTime    DATETIME NULL,

        FacilityID           NVARCHAR(100) NULL,
        LocationID           NVARCHAR(100) NULL,
        ServiceInpatientID   NVARCHAR(100) NULL,
        ServiceOutpatientID  NVARCHAR(100) NULL,

        ExtractedOn          DATETIME NOT NULL DEFAULT SYSDATETIME(),
        ExtractedFrom        NVARCHAR(200) NULL
    );

    BEGIN TRY

        -----------------------------------------------------------------------
        -- Sanity check: ensure required source tables exist
        -----------------------------------------------------------------------
        IF NOT EXISTS (
            SELECT 1 FROM [NBIDRSRV2].[AKULiveATdb].sys.objects
            WHERE name = 'RegAcct_Main' AND type = 'U'
        )
            THROW 50001, 'Missing table: RegAcct_Main', 1;

        IF NOT EXISTS (
            SELECT 1 FROM [NBIDRSRV2].[AKULivendb].sys.objects
            WHERE name = 'AdmVisits' AND type = 'U'
        )
            THROW 50002, 'Missing table: AdmVisits', 1;

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended','U') IS NULL
            THROW 50003, 'Missing FCAP cohort table.', 1;

        -----------------------------------------------------------------------
        -- Pull the latest version of each visit from each source
        -----------------------------------------------------------------------
        ;WITH RegBase AS
        (
            SELECT
                r.SourceID,
                r.VisitID,
                r.PatientID,
                r.RegistrationStatus,
                r.RegistrationType_MisRegTypeID,
                r.Facility_MisFacID,
                r.Location_MisLocID,
                r.ServiceInpatient_MisSvcID,
                r.ServiceOutpatient_MisSvcID,
                r.ArrivalDateTime,
                r.ServiceDateTime,
                r.AdmitDateTime,
                r.RowUpdateDateTime,
                ROW_NUMBER() OVER (
                    PARTITION BY r.SourceID, r.VisitID
                    ORDER BY r.RowUpdateDateTime DESC, r.CreatedDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.RegAcct_Main AS r
        ),
        AdmBase AS
        (
            SELECT
                a.SourceID,
                a.VisitID,
                a.PatientID,
                a.InpatientOrOutpatient,
                a.Status,
                a.FacilityID,
                a.LocationID,
                a.ServiceDateTime,
                a.RowUpdateDateTime,
                ROW_NUMBER() OVER (
                    PARTITION BY a.SourceID, a.VisitID
                    ORDER BY a.RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS a
        )

        INSERT INTO dbo.tbl_FCAP1A_Encounters_Extended
        (
            PatientID,
            VisitID,
            SourceID,

            EncounterClass,
            EncounterType,
            RegistrationStatus,
            VisitStatus,

            StartDateTime,
            EndDateTime,
            AdmitDateTime,
            ArrivalDateTime,
            ServiceDateTime,
            DischargeDateTime,
            RowUpdateDateTime,

            FacilityID,
            LocationID,
            ServiceInpatientID,
            ServiceOutpatientID,

            ExtractedFrom
        )
        SELECT
            c.PatientID,
            r.VisitID,
            r.SourceID,

            a.InpatientOrOutpatient                          AS EncounterClass,
            r.RegistrationType_MisRegTypeID                 AS EncounterType,
            r.RegistrationStatus                            AS RegistrationStatus,
            a.Status                                        AS VisitStatus,

            CASE
                WHEN r.AdmitDateTime IS NOT NULL THEN r.AdmitDateTime
                WHEN r.ArrivalDateTime IS NOT NULL THEN r.ArrivalDateTime
                ELSE r.ServiceDateTime
            END                                              AS StartDateTime,
            NULL                                             AS EndDateTime,
            r.AdmitDateTime,
            r.ArrivalDateTime,
            COALESCE(a.ServiceDateTime, r.ServiceDateTime)   AS ServiceDateTime,
            NULL                                             AS DischargeDateTime,
            COALESCE(a.RowUpdateDateTime, r.RowUpdateDateTime) AS RowUpdateDateTime,

            COALESCE(a.FacilityID, r.Facility_MisFacID)       AS FacilityID,
            COALESCE(a.LocationID, r.Location_MisLocID)       AS LocationID,
            r.ServiceInpatient_MisSvcID                       AS ServiceInpatientID,
            r.ServiceOutpatient_MisSvcID                      AS ServiceOutpatientID,

            N'RegAcct_Main + AdmVisits'
        FROM dbo.tbl_FCAP1A_Cohort10_Extended c
        INNER JOIN RegBase r
            ON r.rn = 1
           AND r.PatientID COLLATE DATABASE_DEFAULT = c.PatientID COLLATE DATABASE_DEFAULT
        LEFT JOIN AdmBase a
            ON a.rn = 1
           AND a.SourceID = r.SourceID
           AND a.VisitID  = r.VisitID
        WHERE
            CASE
                WHEN r.AdmitDateTime IS NOT NULL THEN r.AdmitDateTime
                WHEN r.ArrivalDateTime IS NOT NULL THEN r.ArrivalDateTime
                ELSE r.ServiceDateTime
            END BETWEEN @WindowStart AND @WindowEndNextDay;

        -----------------------------------------------------------------------
        -- Logging
        -----------------------------------------------------------------------
        SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_Encounters_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd, RecordCount,
            ProcessedBy, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
            'Encounters_Extended', @WindowStart, @WindowEnd, @RecordCount,
            SYSTEM_USER,
            N'Encounter spine built using RegAcct_Main (anchor) and AdmVisits (enrichment). Created by Allan Z.'
        );

    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd, ProcessedBy,
            ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds, 'FAILED',
            'Encounters_Extended', @WindowStart, @WindowEnd, SYSTEM_USER,
            @Err, N'Error during Encounters rebuild. Created by Allan Z.'
        );

        THROW;
    END CATCH;
END;
