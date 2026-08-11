/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Providers_Extended]    Script Date: 7/13/2026 3:28:42 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure: dbo.usp_Build_FCAP1A_Providers_Extended

    Purpose:
      - Rebuilds the FCAP 1A Providers_Extended reference dataset
        for the Extended 10% cohort.
      - Creates one row per unique provider/source provider master record.
      - Scopes provider population from existing FCAP provider-bearing topics.
      - Sources provider descriptive/reference attributes from Meditech provider
        master/reference tables.
      - Does not include patient-level, visit-level, referral-level, order-level,
        pathology-level, or event-level relationship rows.
      - Recreates dbo.tbl_FCAP1A_Providers_Extended on each run.
      - Logs execution details to dbo.FCAP1A_Cohort_Log.

    Author:
      Allan Zablon
**comment to nigel** >> Please note that you'll need to QC and validate the logic encased in this uSP. Thanks
    Date:
      2026-05-08

    Grain:
      One row per SourceID + ProviderID.

    Provider scope:
      Provider IDs appearing in current FCAP provider-bearing tables during
      the FCAP 1A date window:
        - dbo.tbl_FCAP1A_PatientReferrals_Extended.ReferralActorID
        - dbo.tbl_FCAP1A_PatientReferrals_Extended.BedRequestAdmitProviderID
        - dbo.tbl_FCAP1A_PatientReferrals_Extended.BedRequestAttendProviderID
        - dbo.tbl_FCAP1A_Medications_Extended.OrderingProviderID
        - dbo.tbl_FCAP1A_PathologyEHR_Extended.AuthorProviderID
        - dbo.tbl_FCAP1A_PathologyReports_Extended.SubmittingProviderID

    Primary provider master:
      [NBIDRSRV2].[AKULivendb].dbo.DMisProvider

    Reference enrichment:
      [NBIDRSRV2].[AKULivendb].dbo.DMisProviderType
      [NBIDRSRV2].[AKULivendb].dbo.DMisProviderGroup
      [NBIDRSRV2].[AKULiveATdb].dbo.MisSvc_Main
      [NBIDRSRV2].[AKULiveATdb].dbo.MisSpec_Main

    Notes:
      - Provider is a reference/master topic.
      - PatientID and VisitID are used only upstream in the existing FCAP tables
        that define the provider population. They are not stored here.
      - Medications currently has OrderingProviderID but no SourceID in the
        FCAP output schema. Since AKU SourceID is effectively uniform, this
        procedure resolves medication providers by ProviderID and takes SourceID
        from DMisProvider.
      - OMOP concept fields are included as nullable placeholders where source
        data does not directly provide OMOP vocabulary mappings.
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Providers_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart          DATETIME = SYSDATETIME(),
        @RunEnd            DATETIME,
        @DurationSeconds   INT,
        @RecordCount       INT = 0,
        @TotalEligible     INT = NULL,
        @WindowStart       DATE = '2022-11-05',
        @WindowEnd         DATE = '2026-06-14',
        @WindowEndNextDay  DATE = DATEADD(DAY, 1, '2026-06-14');

    -------------------------------------------------------------------------
    -- 1. Ensure log table exists
    -------------------------------------------------------------------------

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log', 'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log
        (
            LogID             INT IDENTITY(1,1) PRIMARY KEY,
            RunStart          DATETIME        NOT NULL,
            RunEnd            DATETIME            NULL,
            DurationSeconds   INT                 NULL,
            RunStatus         VARCHAR(20)     NOT NULL,
            DataTopic         NVARCHAR(100)   NOT NULL,
            WindowStart       DATE                NULL,
            WindowEnd         DATE                NULL,
            TotalEligible     INT                 NULL,
            RecordCount       INT                 NULL,
            ProcessedBy       NVARCHAR(100)   NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage      NVARCHAR(4000)      NULL,
            Remarks           NVARCHAR(4000)      NULL
        );
    END;

    -------------------------------------------------------------------------
    -- 2. Recreate output table
    --    Grain: one row per SourceID + ProviderID
    -------------------------------------------------------------------------

    IF OBJECT_ID('dbo.tbl_FCAP1A_Providers_Extended', 'U') IS NOT NULL
    BEGIN
        DROP TABLE dbo.tbl_FCAP1A_Providers_Extended;
    END;

    CREATE TABLE dbo.tbl_FCAP1A_Providers_Extended
    (
        ProviderRowID INT IDENTITY(1,1) PRIMARY KEY,

        -- Natural key / linkage
        SourceID                    NVARCHAR(50)    NOT NULL,
        ProviderID                  NVARCHAR(255)   NOT NULL,
        SourceProviderKey           NVARCHAR(400)   NOT NULL,
        ProviderSourceValue         NVARCHAR(255)       NULL,

        -- Core provider identity
        ProviderName                NVARCHAR(255)       NULL,
        ProviderFirstName           NVARCHAR(255)       NULL,
        ProviderMiddleName          NVARCHAR(255)       NULL,
        ProviderLastName            NVARCHAR(255)       NULL,
        ProviderNumber              NVARCHAR(255)       NULL,

        -- Provider type
        ProviderTypeCode            NVARCHAR(255)       NULL,
        ProviderTypeName            NVARCHAR(255)       NULL,
        ProviderTypeActiveFlag      NVARCHAR(20)        NULL,
        ProviderTypeIsPhysicianFlag NVARCHAR(20)        NULL,

        -- Provider group
        ProviderGroupCode           NVARCHAR(255)       NULL,
        ProviderGroupName           NVARCHAR(255)       NULL,
        ProviderGroupActiveFlag     NVARCHAR(20)        NULL,

        -- Provider service
        ProviderServiceCode         NVARCHAR(255)       NULL,
        ProviderServiceName         NVARCHAR(255)       NULL,
        ProviderServiceActiveFlag   NVARCHAR(20)        NULL,

        -- Provider specialty
        ProviderSpecialtyCode       NVARCHAR(255)       NULL,
        ProviderSpecialtyName       NVARCHAR(255)       NULL,
        ProviderSpecialtyType       NVARCHAR(255)       NULL,
        ProviderSpecialtyActiveFlag NVARCHAR(20)        NULL,
        SpecialtySourceValue        NVARCHAR(255)       NULL,

        -- OMOP-compatible placeholders
        SpecialtyConceptID          INT                 NULL,
        SpecialtySourceConceptID    INT                 NULL,
        CareSiteID                  INT                 NULL,

        -- Approved provider identifiers
        Npi                         NVARCHAR(255)       NULL,
        ProviderLicenseNumber       NVARCHAR(255)       NULL,
        Dea                         NVARCHAR(255)       NULL,

        -- Provider status / privileges
        ProviderActiveFlag          NVARCHAR(20)        NULL,
        ProviderOnStaffFlag         NVARCHAR(20)        NULL,
        ProviderAdmitPrivilegeFlag  NVARCHAR(20)        NULL,
        ProviderOrderFlag           NVARCHAR(20)        NULL,

        -- ETL metadata
        RowUpdateDateTime           DATETIME            NULL,
        ExtractedFrom               NVARCHAR(500)       NULL,
        ExtractedOn                 DATETIME        NOT NULL DEFAULT (SYSDATETIME())
    );

    -------------------------------------------------------------------------
    -- 3. Build provider reference rows
    -------------------------------------------------------------------------

    BEGIN TRY

        ---------------------------------------------------------------------
        -- 3a. Determine total eligible patients for logging / QC
        ---------------------------------------------------------------------

        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ---------------------------------------------------------------------
        -- 3b. Build provider inclusion set from current FCAP provider-bearing
        --     tables.
        --
        --     Important:
        --       - These tables define scope only.
        --       - PatientID, VisitID, ReferralID, PrescriptionID, SpecimenID,
        --         DocumentID, and event-level details are not carried forward.
        ---------------------------------------------------------------------

        ;WITH ProviderScopeRaw AS
        (
            -----------------------------------------------------------------
            -- Patient Referrals: generic referral actor
            -----------------------------------------------------------------
            SELECT DISTINCT
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), SourceID))), '') AS SourceID,
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), ReferralActorID))), '') AS ProviderID
            FROM dbo.tbl_FCAP1A_PatientReferrals_Extended
            WHERE ReferralActorID IS NOT NULL
              AND (
                    COALESCE(ReferralDateTime, ServiceDateTime, RowUpdateDateTime) >= @WindowStart
                AND COALESCE(ReferralDateTime, ServiceDateTime, RowUpdateDateTime) <  @WindowEndNextDay
              )

            UNION

            -----------------------------------------------------------------
            -- Patient Referrals: bed request admitting provider
            -----------------------------------------------------------------
            SELECT DISTINCT
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), SourceID))), '') AS SourceID,
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), BedRequestAdmitProviderID))), '') AS ProviderID
            FROM dbo.tbl_FCAP1A_PatientReferrals_Extended
            WHERE BedRequestAdmitProviderID IS NOT NULL
              AND (
                    COALESCE(ReferralDateTime, ServiceDateTime, RowUpdateDateTime) >= @WindowStart
                AND COALESCE(ReferralDateTime, ServiceDateTime, RowUpdateDateTime) <  @WindowEndNextDay
              )

            UNION

            -----------------------------------------------------------------
            -- Patient Referrals: bed request attending provider
            -----------------------------------------------------------------
            SELECT DISTINCT
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), SourceID))), '') AS SourceID,
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), BedRequestAttendProviderID))), '') AS ProviderID
            FROM dbo.tbl_FCAP1A_PatientReferrals_Extended
            WHERE BedRequestAttendProviderID IS NOT NULL
              AND (
                    COALESCE(ReferralDateTime, ServiceDateTime, RowUpdateDateTime) >= @WindowStart
                AND COALESCE(ReferralDateTime, ServiceDateTime, RowUpdateDateTime) <  @WindowEndNextDay
              )

            UNION

            -----------------------------------------------------------------
            -- Medications: ordering provider
            --
            -- Current FCAP Medications schema has OrderingProviderID but does
            -- not expose SourceID. We therefore scope by ProviderID only and
            -- resolve SourceID from DMisProvider.
            -----------------------------------------------------------------
            SELECT DISTINCT
                CAST(NULL AS NVARCHAR(50)) AS SourceID,
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), OrderingProviderID))), '') AS ProviderID
            FROM dbo.tbl_FCAP1A_Medications_Extended
            WHERE OrderingProviderID IS NOT NULL
              AND (
                    COALESCE(EventDateTime, OrderDateTime, RowUpdateDateTime) >= @WindowStart
                AND COALESCE(EventDateTime, OrderDateTime, RowUpdateDateTime) <  @WindowEndNextDay
              )

            UNION

            -----------------------------------------------------------------
            -- Pathology EHR: author provider
            -----------------------------------------------------------------
            SELECT DISTINCT
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), SourceID))), '') AS SourceID,
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), AuthorProviderID))), '') AS ProviderID
            FROM dbo.tbl_FCAP1A_PathologyEHR_Extended
            WHERE AuthorProviderID IS NOT NULL
              AND (
                    COALESCE(NoteDateTime, FinalReportDateTime, ReceivedDateTime, RowUpdateDateTime) >= @WindowStart
                AND COALESCE(NoteDateTime, FinalReportDateTime, ReceivedDateTime, RowUpdateDateTime) <  @WindowEndNextDay
              )

            UNION

            -----------------------------------------------------------------
            -- Pathology Reports: submitting provider
            -----------------------------------------------------------------
            SELECT DISTINCT
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), SourceID))), '') AS SourceID,
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), SubmittingProviderID))), '') AS ProviderID
            FROM dbo.tbl_FCAP1A_PathologyReports_Extended
            WHERE SubmittingProviderID IS NOT NULL
              AND (
                    COALESCE(ClinicalDateTime, FinalReportDateTime, ReceivedDateTime, RowUpdateDateTime) >= @WindowStart
                AND COALESCE(ClinicalDateTime, FinalReportDateTime, ReceivedDateTime, RowUpdateDateTime) <  @WindowEndNextDay
              )
        ),
        ProviderScope AS
        (
            SELECT DISTINCT
                SourceID,
                ProviderID
            FROM ProviderScopeRaw
            WHERE ProviderID IS NOT NULL
        ),
        ProviderMaster AS
        (
            SELECT DISTINCT
                p.SourceID,
                p.ProviderID,

                p.Name,
                p.FirstName,
                p.MiddleInitial,
                p.LastName,
                p.Number,

                p.ProviderTypeID,
                pt.Name AS ProviderTypeName,
                pt.Active AS ProviderTypeActive,
                pt.IsPhysician AS ProviderTypeIsPhysician,

                p.ProviderGroupID,
                pg.Name AS ProviderGroupName,
                pg.Active AS ProviderGroupActive,

                p.ServiceID,
                svc.Name AS ProviderServiceName,
                svc.Active AS ProviderServiceActive,

                p.SpecialtyAbsServiceID,
                spec.Name AS ProviderSpecialtyName,
                spec.SpecialtyType AS ProviderSpecialtyType,
                spec.Active AS ProviderSpecialtyActive,

                p.NationalProviderIdNumber,
                p.LicenseNumber,
                p.DeaNumber,

                p.Active,
                p.OnStaff,
                p.AdmitPrivilege,
                p.ProviderOrder,

                (
                    SELECT MAX(UpdateDateTimeValue)
                    FROM
                    (
                        VALUES
                            (p.RowUpdateDateTime),
                            (pt.RowUpdateDateTime),
                            (pg.RowUpdateDateTime),
                            (svc.RowUpdateDateTime),
                            (spec.RowUpdateDateTime)
                    ) AS UpdateDates(UpdateDateTimeValue)
                ) AS MaxRowUpdateDateTime

            FROM [NBIDRSRV2].[AKULivendb].dbo.DMisProvider AS p

            INNER JOIN ProviderScope AS s
                ON p.ProviderID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = s.ProviderID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND (
                        s.SourceID IS NULL
                     OR p.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
                        = s.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
                   )

            LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.DMisProviderType AS pt
                ON p.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = pt.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND p.ProviderTypeID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = pt.ProviderTypeID COLLATE SQL_Latin1_General_CP1_CI_AS

            LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.DMisProviderGroup AS pg
                ON p.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = pg.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND p.ProviderGroupID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = pg.ProviderGroupID COLLATE SQL_Latin1_General_CP1_CI_AS

            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].dbo.MisSvc_Main AS svc
                ON p.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = svc.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND p.ServiceID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = svc.MisSvcID COLLATE SQL_Latin1_General_CP1_CI_AS

            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].dbo.MisSpec_Main AS spec
                ON p.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = spec.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND p.SpecialtyAbsServiceID COLLATE SQL_Latin1_General_CP1_CI_AS
                   = spec.MisSpecID COLLATE SQL_Latin1_General_CP1_CI_AS
        )

        ---------------------------------------------------------------------
        -- 3c. Insert provider master/reference rows
        ---------------------------------------------------------------------

        INSERT INTO dbo.tbl_FCAP1A_Providers_Extended
        (
            SourceID,
            ProviderID,
            SourceProviderKey,
            ProviderSourceValue,

            ProviderName,
            ProviderFirstName,
            ProviderMiddleName,
            ProviderLastName,
            ProviderNumber,

            ProviderTypeCode,
            ProviderTypeName,
            ProviderTypeActiveFlag,
            ProviderTypeIsPhysicianFlag,

            ProviderGroupCode,
            ProviderGroupName,
            ProviderGroupActiveFlag,

            ProviderServiceCode,
            ProviderServiceName,
            ProviderServiceActiveFlag,

            ProviderSpecialtyCode,
            ProviderSpecialtyName,
            ProviderSpecialtyType,
            ProviderSpecialtyActiveFlag,
            SpecialtySourceValue,

            SpecialtyConceptID,
            SpecialtySourceConceptID,
            CareSiteID,

            Npi,
            ProviderLicenseNumber,
            Dea,

            ProviderActiveFlag,
            ProviderOnStaffFlag,
            ProviderAdmitPrivilegeFlag,
            ProviderOrderFlag,

            RowUpdateDateTime,
            ExtractedFrom
        )
        SELECT DISTINCT
            CONVERT(NVARCHAR(50), pm.SourceID) AS SourceID,
            CONVERT(NVARCHAR(255), pm.ProviderID) AS ProviderID,
            CONVERT(NVARCHAR(400), CONCAT(pm.SourceID, ':', pm.ProviderID)) AS SourceProviderKey,
            CONVERT(NVARCHAR(255), pm.ProviderID) AS ProviderSourceValue,

            CONVERT(NVARCHAR(255), pm.Name) AS ProviderName,
            CONVERT(NVARCHAR(255), pm.FirstName) AS ProviderFirstName,
            CONVERT(NVARCHAR(255), pm.MiddleInitial) AS ProviderMiddleName,
            CONVERT(NVARCHAR(255), pm.LastName) AS ProviderLastName,
            CONVERT(NVARCHAR(255), pm.Number) AS ProviderNumber,

            CONVERT(NVARCHAR(255), pm.ProviderTypeID) AS ProviderTypeCode,
            CONVERT(NVARCHAR(255), pm.ProviderTypeName) AS ProviderTypeName,
            CONVERT(NVARCHAR(20), pm.ProviderTypeActive) AS ProviderTypeActiveFlag,
            CONVERT(NVARCHAR(20), pm.ProviderTypeIsPhysician) AS ProviderTypeIsPhysicianFlag,

            CONVERT(NVARCHAR(255), pm.ProviderGroupID) AS ProviderGroupCode,
            CONVERT(NVARCHAR(255), pm.ProviderGroupName) AS ProviderGroupName,
            CONVERT(NVARCHAR(20), pm.ProviderGroupActive) AS ProviderGroupActiveFlag,

            CONVERT(NVARCHAR(255), pm.ServiceID) AS ProviderServiceCode,
            CONVERT(NVARCHAR(255), pm.ProviderServiceName) AS ProviderServiceName,
            CONVERT(NVARCHAR(20), pm.ProviderServiceActive) AS ProviderServiceActiveFlag,

            CONVERT(NVARCHAR(255), pm.SpecialtyAbsServiceID) AS ProviderSpecialtyCode,
            CONVERT(NVARCHAR(255), pm.ProviderSpecialtyName) AS ProviderSpecialtyName,
            CONVERT(NVARCHAR(255), pm.ProviderSpecialtyType) AS ProviderSpecialtyType,
            CONVERT(NVARCHAR(20), pm.ProviderSpecialtyActive) AS ProviderSpecialtyActiveFlag,
            CONVERT(NVARCHAR(255), pm.SpecialtyAbsServiceID) AS SpecialtySourceValue,

            CAST(NULL AS INT) AS SpecialtyConceptID,
            CAST(NULL AS INT) AS SpecialtySourceConceptID,
            CAST(NULL AS INT) AS CareSiteID,

            CONVERT(NVARCHAR(255), pm.NationalProviderIdNumber) AS Npi,
            CONVERT(NVARCHAR(255), pm.LicenseNumber) AS ProviderLicenseNumber,
            CONVERT(NVARCHAR(255), pm.DeaNumber) AS Dea,

            CONVERT(NVARCHAR(20), pm.Active) AS ProviderActiveFlag,
            CONVERT(NVARCHAR(20), pm.OnStaff) AS ProviderOnStaffFlag,
            CONVERT(NVARCHAR(20), pm.AdmitPrivilege) AS ProviderAdmitPrivilegeFlag,
            CONVERT(NVARCHAR(20), pm.ProviderOrder) AS ProviderOrderFlag,

            pm.MaxRowUpdateDateTime AS RowUpdateDateTime,
            N'DMisProvider; DMisProviderType; DMisProviderGroup; MisSvc_Main; MisSpec_Main; scoped from current FCAP provider-bearing tables' AS ExtractedFrom
        FROM ProviderMaster AS pm;

        ---------------------------------------------------------------------
        -- 4. Post-insert counts and timing
        ---------------------------------------------------------------------

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_Providers_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        ---------------------------------------------------------------------
        -- 5. Log success
        ---------------------------------------------------------------------

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
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
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'Providers_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            N'Providers_Extended rebuild completed successfully. Provider scope derived from current FCAP provider-bearing tables; output grain is one row per SourceID + ProviderID.'
        );

        PRINT 'Providers_Extended rebuild completed successfully.';
        PRINT 'Rows inserted: ' + CAST(@RecordCount AS VARCHAR(20));
        PRINT 'Total eligible patients (cohort): ' + ISNULL(CAST(@TotalEligible AS VARCHAR(20)), 'NULL');
        PRINT 'Duration (seconds): ' + CAST(@DurationSeconds AS VARCHAR(20));

    END TRY
    BEGIN CATCH

        ---------------------------------------------------------------------
        -- 6. Log failure and rethrow
        ---------------------------------------------------------------------

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
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
        VALUES
        (
            @RunStart,
            SYSDATETIME(),
            NULL,
            'FAILED',
            N'Providers_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @ErrMsg,
            N'Error during Providers_Extended rebuild.'
        );

        THROW;
    END CATCH;
END;
