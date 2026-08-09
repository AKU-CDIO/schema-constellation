USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_PatientReferrals_Extended]    Script Date: 7/13/2026 5:19:46 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
Created by @Allan.z ,@Derick.v please use this as a launch pad for exploration of meditech.


    Stored Procedure: dbo.usp_Build_FCAP1A_PatientReferrals_Extended

    Purpose:
        Builds the FCAP 1A Patient Referrals dataset for the Extended cohort.

        This topic captures visit-linked referral, admission-source, consulting-provider,
        and bed-request routing context.

        It intentionally does NOT include provider descriptive attributes such as:
            - provider name
            - provider specialty
            - provider credentials
            - provider phone/email/address
            - provider department
            - provider master metadata

        Provider/source identifiers are retained only as relationship keys.

    Grain:
        One row per patient, visit, source, referral context type, referral role,
        referral actor, referral datetime, and source table.

    FCAP Scope:
        Cohort:
            dbo.tbl_FCAP1A_Cohort10_Extended

        Date Window:
            2022-11-05 through 2026-01-31 inclusive
			updated to 
			2022-11-05 through 2026-06-14 inclusive

    Source Tables:
        [NBIDRSRV2].[AKULivendb].dbo.AdmVisits
        [NBIDRSRV2].[AKULivendb].dbo.AdmProviders
        [NBIDRSRV2].[AKULivendb].dbo.AdmConsultingProviders
        [NBIDRSRV2].[AKULivendb].dbo.AdmittingData
        [NBIDRSRV2].[AKULivendb].dbo.DMisAdmitSource

    Notes:
        - AdmVisits is used only as the visit/patient/date anchor.
        - Provider role rows are unpivoted from AdmProviders.
        - Consulting provider rows are sourced separately because one visit can have
          multiple consulting providers.
        - Admission source and bed request rows are included only as referral/access
          routing context.
        - No full encounter spine is rebuilt here.
        - No ADT movement, room, bed, accommodation, discharge, address, phone, or email
          fields are included.
        - No provider master attributes are included.

    Author:
        Allan Z.

    Version:
        Extended

    Development Date:
        2026-05-03
	Revised date
		2026-07-13
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_PatientReferrals_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart           DATETIME = SYSDATETIME(),
        @RunEnd             DATETIME,
        @DurationSeconds    INT,
        @RecordCount        INT = 0,
        @WindowStart        DATE = '2022-11-05',
        @WindowEnd          DATE = '2026-06-14',
        @WindowEndNextDay   DATE;

    SET @WindowEndNextDay = DATEADD(DAY, 1, @WindowEnd);

    -----------------------------------------------------------------------
    -- Ensure FCAP log table exists
    -----------------------------------------------------------------------
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log', 'U') IS NULL
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
    IF OBJECT_ID('dbo.tbl_FCAP1A_PatientReferrals_Extended', 'U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_PatientReferrals_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_PatientReferrals_Extended
    (
        PatientReferralID              INT IDENTITY(1,1) PRIMARY KEY,

        PatientID                      NVARCHAR(255) NOT NULL,
        VisitID                        NVARCHAR(255) NOT NULL,
        SourceID                       NVARCHAR(50)  NOT NULL,

        ReferralContextType            NVARCHAR(100) NOT NULL,
        ReferralRole                   NVARCHAR(100) NOT NULL,
        ReferralActorID                NVARCHAR(255) NULL,
        ReferralActorType              NVARCHAR(100) NULL,

        ReferralDateTime               DATETIME NULL,

        ReferralSourceValue            NVARCHAR(255) NULL,
        ReferralSourceName             NVARCHAR(255) NULL,
        ReferralSourceTypeID           NVARCHAR(255) NULL,
        ReferralSourceTypeDescription  NVARCHAR(255) NULL,

        AdmitSourceID                  NVARCHAR(255) NULL,
        AdmitSourceName                NVARCHAR(255) NULL,

        ReferralPriorityID             NVARCHAR(255) NULL,
        ReferralStatus                 NVARCHAR(255) NULL,
        ReferralServiceID              NVARCHAR(255) NULL,

        BedRequestSource               NVARCHAR(255) NULL,
        BedRequestAdmitSourceID        NVARCHAR(255) NULL,
        BedRequestAdmitProviderID      NVARCHAR(255) NULL,
        BedRequestAttendProviderID     NVARCHAR(255) NULL,

        ServiceDateTime                DATETIME NULL,

        SourceTable                    NVARCHAR(200) NOT NULL,
        RowUpdateDateTime              DATETIME NULL,
        ExtractedOn                    DATETIME NOT NULL DEFAULT SYSDATETIME()
    );

    BEGIN TRY

        -----------------------------------------------------------------------
        -- Sanity checks: required objects
        -----------------------------------------------------------------------
        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended', 'U') IS NULL
            THROW 51001, 'Missing required table: dbo.tbl_FCAP1A_Cohort10_Extended', 1;

        IF NOT EXISTS (
            SELECT 1
            FROM [NBIDRSRV2].[AKULivendb].sys.objects
            WHERE name = 'AdmVisits'
              AND type = 'U'
        )
            THROW 51002, 'Missing source table: [NBIDRSRV2].[AKULivendb].dbo.AdmVisits', 1;

        IF NOT EXISTS (
            SELECT 1
            FROM [NBIDRSRV2].[AKULivendb].sys.objects
            WHERE name = 'AdmProviders'
              AND type = 'U'
        )
            THROW 51003, 'Missing source table: [NBIDRSRV2].[AKULivendb].dbo.AdmProviders', 1;

        IF NOT EXISTS (
            SELECT 1
            FROM [NBIDRSRV2].[AKULivendb].sys.objects
            WHERE name = 'AdmConsultingProviders'
              AND type = 'U'
        )
            THROW 51004, 'Missing source table: [NBIDRSRV2].[AKULivendb].dbo.AdmConsultingProviders', 1;

        IF NOT EXISTS (
            SELECT 1
            FROM [NBIDRSRV2].[AKULivendb].sys.objects
            WHERE name = 'AdmittingData'
              AND type = 'U'
        )
            THROW 51005, 'Missing source table: [NBIDRSRV2].[AKULivendb].dbo.AdmittingData', 1;

        -----------------------------------------------------------------------
        -- Build referral context rows
        -----------------------------------------------------------------------
        ;WITH VisitBase AS
        (
            SELECT
                v.SourceID,
                v.VisitID,
                v.PatientID,
                v.ServiceDateTime,
                v.RowUpdateDateTime,
                ROW_NUMBER() OVER
                (
                    PARTITION BY v.SourceID, v.VisitID
                    ORDER BY v.RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended AS c
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE v.ServiceDateTime >= @WindowStart
              AND v.ServiceDateTime <  @WindowEndNextDay
        ),
        ProviderBase AS
        (
            SELECT
                p.SourceID,
                p.VisitID,
                p.ReferID,
                p.AdmitID,
                p.AttendID,
                p.EmergencyID,
                p.FamilyID,
                p.OtherID,
                p.PrimaryCareID,
                p.RowUpdateDateTime,
                ROW_NUMBER() OVER
                (
                    PARTITION BY p.SourceID, p.VisitID
                    ORDER BY p.RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmProviders AS p
        ),
        ProviderRoleRows AS
        (
            SELECT
                vb.PatientID,
                pb.VisitID,
                pb.SourceID,
                N'PROVIDER_ROLE' AS ReferralContextType,
                RoleMap.ReferralRole,
                RoleMap.ReferralActorID,
                N'PROVIDER' AS ReferralActorType,
                vb.ServiceDateTime AS ReferralDateTime,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceValue,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceName,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeID,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeDescription,
                CAST(NULL AS NVARCHAR(255)) AS AdmitSourceID,
                CAST(NULL AS NVARCHAR(255)) AS AdmitSourceName,
                CAST(NULL AS NVARCHAR(255)) AS ReferralPriorityID,
                CAST(NULL AS NVARCHAR(255)) AS ReferralStatus,
                CAST(NULL AS NVARCHAR(255)) AS ReferralServiceID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestSource,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAdmitSourceID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAdmitProviderID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAttendProviderID,
                vb.ServiceDateTime,
                N'AdmProviders' AS SourceTable,
                COALESCE(pb.RowUpdateDateTime, vb.RowUpdateDateTime) AS RowUpdateDateTime
            FROM ProviderBase AS pb
            INNER JOIN VisitBase AS vb
                ON vb.rn = 1
               AND vb.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   pb.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND vb.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   pb.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            CROSS APPLY
            (
                VALUES
                    (N'Referring Provider',    pb.ReferID),
                    (N'Admitting Provider',    pb.AdmitID),
                    (N'Attending Provider',    pb.AttendID),
                    (N'Emergency Provider',    pb.EmergencyID),
                    (N'Family Provider',       pb.FamilyID),
                    (N'Other Provider',        pb.OtherID),
                    (N'Primary Care Provider', pb.PrimaryCareID)
            ) AS RoleMap (ReferralRole, ReferralActorID)
            WHERE pb.rn = 1
              AND RoleMap.ReferralActorID IS NOT NULL
        ),
        ConsultingProviderRows AS
        (
            SELECT DISTINCT
                vb.PatientID,
                cp.VisitID,
                cp.SourceID,
                N'CONSULTING_PROVIDER' AS ReferralContextType,
                N'Consulting Provider' AS ReferralRole,
                cp.ConsultingID AS ReferralActorID,
                N'PROVIDER' AS ReferralActorType,
                vb.ServiceDateTime AS ReferralDateTime,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceValue,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceName,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeID,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeDescription,
                CAST(NULL AS NVARCHAR(255)) AS AdmitSourceID,
                CAST(NULL AS NVARCHAR(255)) AS AdmitSourceName,
                CAST(NULL AS NVARCHAR(255)) AS ReferralPriorityID,
                CAST(NULL AS NVARCHAR(255)) AS ReferralStatus,
                CAST(NULL AS NVARCHAR(255)) AS ReferralServiceID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestSource,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAdmitSourceID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAdmitProviderID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAttendProviderID,
                vb.ServiceDateTime,
                N'AdmConsultingProviders' AS SourceTable,
                COALESCE(cp.RowUpdateDateTime, vb.RowUpdateDateTime) AS RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmConsultingProviders AS cp
            INNER JOIN VisitBase AS vb
                ON vb.rn = 1
               AND vb.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   cp.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND vb.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   cp.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE cp.ConsultingID IS NOT NULL
        ),
        AdmissionSourceRows AS
        (
            SELECT DISTINCT
                vb.PatientID,
                ad.VisitID,
                ad.SourceID,
                N'ADMISSION_SOURCE' AS ReferralContextType,
                N'Admission Source' AS ReferralRole,
                ad.AdmitSourceID AS ReferralActorID,
                N'ADMISSION_SOURCE' AS ReferralActorType,
                COALESCE(ad.AdmitDateTime, vb.ServiceDateTime) AS ReferralDateTime,
                ad.AdmitSourceID AS ReferralSourceValue,
                mas.Name AS ReferralSourceName,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeID,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeDescription,
                ad.AdmitSourceID,
                mas.Name AS AdmitSourceName,
                ad.AdmitPriorityID AS ReferralPriorityID,
                CAST(NULL AS NVARCHAR(255)) AS ReferralStatus,
                CAST(NULL AS NVARCHAR(255)) AS ReferralServiceID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestSource,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAdmitSourceID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAdmitProviderID,
                CAST(NULL AS NVARCHAR(255)) AS BedRequestAttendProviderID,
                vb.ServiceDateTime,
                N'AdmittingData' AS SourceTable,
                COALESCE(ad.RowUpdateDateTime, vb.RowUpdateDateTime) AS RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmittingData AS ad
            INNER JOIN VisitBase AS vb
                ON vb.rn = 1
               AND vb.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND vb.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.DMisAdmitSource AS mas
                ON mas.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND mas.AdmitSourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.AdmitSourceID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE ad.AdmitSourceID IS NOT NULL
        ),
        BedRequestRows AS
        (
            SELECT DISTINCT
                vb.PatientID,
                ad.VisitID,
                ad.SourceID,
                BedMap.ReferralContextType,
                BedMap.ReferralRole,
                BedMap.ReferralActorID,
                BedMap.ReferralActorType,
                COALESCE(ad.BedRequestDateTime, ad.AdmitDateTime, vb.ServiceDateTime) AS ReferralDateTime,
                BedMap.ReferralActorID AS ReferralSourceValue,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceName,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeID,
                CAST(NULL AS NVARCHAR(255)) AS ReferralSourceTypeDescription,
                ad.AdmitSourceID,
                mas.Name AS AdmitSourceName,
                ad.AdmitPriorityID AS ReferralPriorityID,
                ad.BedRequestStatus AS ReferralStatus,
                CASE
                    WHEN BedMap.ReferralRole = N'Bed Request Service'
                        THEN ad.BedRequestServiceID
                    ELSE NULL
                END AS ReferralServiceID,
                ad.BedRequestSource,
                ad.BedRequestAdmitSourceID,
                ad.BedRequestAdmitProviderID,
                ad.BedRequestAttendProviderID,
                vb.ServiceDateTime,
                N'AdmittingData' AS SourceTable,
                COALESCE(ad.RowUpdateDateTime, vb.RowUpdateDateTime) AS RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmittingData AS ad
            INNER JOIN VisitBase AS vb
                ON vb.rn = 1
               AND vb.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND vb.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.DMisAdmitSource AS mas
                ON mas.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND mas.AdmitSourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ad.AdmitSourceID COLLATE SQL_Latin1_General_CP1_CI_AS
            CROSS APPLY
            (
                VALUES
                    (
                        N'BED_REQUEST',
                        N'Bed Request Source',
                        ad.BedRequestSource,
                        N'BED_REQUEST_SOURCE'
                    ),
                    (
                        N'BED_REQUEST',
                        N'Bed Request Admit Source',
                        ad.BedRequestAdmitSourceID,
                        N'ADMISSION_SOURCE'
                    ),
                    (
                        N'BED_REQUEST',
                        N'Bed Request Admit Provider',
                        ad.BedRequestAdmitProviderID,
                        N'PROVIDER'
                    ),
                    (
                        N'BED_REQUEST',
                        N'Bed Request Attending Provider',
                        ad.BedRequestAttendProviderID,
                        N'PROVIDER'
                    ),
                    (
                        N'BED_REQUEST',
                        N'Bed Request Service',
                        ad.BedRequestServiceID,
                        N'SERVICE'
                    )
            ) AS BedMap
            (
                ReferralContextType,
                ReferralRole,
                ReferralActorID,
                ReferralActorType
            )
            WHERE BedMap.ReferralActorID IS NOT NULL
        ),
        CombinedRows AS
        (
            SELECT * FROM ProviderRoleRows
            UNION ALL
            SELECT * FROM ConsultingProviderRows
            UNION ALL
            SELECT * FROM AdmissionSourceRows
            UNION ALL
            SELECT * FROM BedRequestRows
        ),
        DedupedRows AS
        (
            SELECT
                cr.*,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        cr.PatientID,
                        cr.VisitID,
                        cr.SourceID,
                        cr.ReferralContextType,
                        cr.ReferralRole,
                        cr.ReferralActorID,
                        cr.ReferralDateTime,
                        cr.SourceTable
                    ORDER BY
                        cr.RowUpdateDateTime DESC
                ) AS rn
            FROM CombinedRows AS cr
        )
        INSERT INTO dbo.tbl_FCAP1A_PatientReferrals_Extended
        (
            PatientID,
            VisitID,
            SourceID,

            ReferralContextType,
            ReferralRole,
            ReferralActorID,
            ReferralActorType,

            ReferralDateTime,

            ReferralSourceValue,
            ReferralSourceName,
            ReferralSourceTypeID,
            ReferralSourceTypeDescription,

            AdmitSourceID,
            AdmitSourceName,

            ReferralPriorityID,
            ReferralStatus,
            ReferralServiceID,

            BedRequestSource,
            BedRequestAdmitSourceID,
            BedRequestAdmitProviderID,
            BedRequestAttendProviderID,

            ServiceDateTime,

            SourceTable,
            RowUpdateDateTime,
            ExtractedOn
        )
        SELECT
            PatientID,
            VisitID,
            SourceID,

            ReferralContextType,
            ReferralRole,
            ReferralActorID,
            ReferralActorType,

            ReferralDateTime,

            ReferralSourceValue,
            ReferralSourceName,
            ReferralSourceTypeID,
            ReferralSourceTypeDescription,

            AdmitSourceID,
            AdmitSourceName,

            ReferralPriorityID,
            ReferralStatus,
            ReferralServiceID,

            BedRequestSource,
            BedRequestAdmitSourceID,
            BedRequestAdmitProviderID,
            BedRequestAttendProviderID,

            ServiceDateTime,

            SourceTable,
            RowUpdateDateTime,
            SYSDATETIME()
        FROM DedupedRows
        WHERE rn = 1;

        -----------------------------------------------------------------------
        -- Helpful indexes after rebuild
        -----------------------------------------------------------------------
        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_PatientReferrals_Extended_PatientVisit
            ON dbo.tbl_FCAP1A_PatientReferrals_Extended
            (
                PatientID,
                VisitID,
                SourceID
            );

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_PatientReferrals_Extended_ContextRole
            ON dbo.tbl_FCAP1A_PatientReferrals_Extended
            (
                ReferralContextType,
                ReferralRole,
                ReferralActorType
            );

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_PatientReferrals_Extended_ReferralDateTime
            ON dbo.tbl_FCAP1A_PatientReferrals_Extended
            (
                ReferralDateTime
            );

        -----------------------------------------------------------------------
        -- Logging
        -----------------------------------------------------------------------
        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_PatientReferrals_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
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
            'PatientReferrals_Extended',
            @WindowStart,
            @WindowEnd,
            @RecordCount,
            SYSTEM_USER,
            N'Patient Referrals build completed. Topic stores visit-linked referral/provider-role/admission-source context only. Provider descriptive attributes intentionally excluded.'
        );

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            'PatientReferrals_Extended',
            @WindowStart,
            @WindowEnd,
            SYSTEM_USER,
            @Err,
            N'Patient Referrals build failed.'
        );

        THROW;

    END CATCH;
END;
