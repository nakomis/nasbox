import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as iot from 'aws-cdk-lib/aws-iot';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { ThingWithCert } from 'cdk-iot-core-certificates-v3';

const THING_NAME = 'nasbox';
const ROLE_ALIAS = 'NasboxRoleAlias';

export class NasboxIotStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ── Hosted zone lookup ────────────────────────────────────────────────────
    // Resolved at synth time and cached in cdk.context.json.
    const hostedZone = route53.HostedZone.fromLookup(this, 'NakomisComZone', {
      domainName: 'nakomis.com',
    });

    // ── IoT Thing + certificate ───────────────────────────────────────────────
    // Certificate and private key are saved to SSM Parameter Store under
    // /nasbox/certPem and /nasbox/privKey respectively.
    const thingWithCert = new ThingWithCert(this, 'NasboxThing', {
      thingName: THING_NAME,
      saveToParamStore: true,
      paramPrefix: 'nasbox',
    });
    const { thingArn, certId } = thingWithCert;
    const certArn = `arn:aws:iot:${this.region}:${this.account}:cert/${certId}`;

    // ── IAM role assumed via IoT credential provider ──────────────────────────
    // The Pi exchanges its IoT certificate for short-lived STS credentials
    // scoped to this role. No long-lived AWS credentials live on the Pi.
    const nasboxRole = new iam.Role(this, 'NasboxIamRole', {
      roleName: 'NasboxThingIamRole',
      description: 'Assumed by the nasbox Pi via IoT credential provider',
      assumedBy: new iam.ServicePrincipal('credentials.iot.amazonaws.com'),
    });

    const nasboxPolicy = new iam.Policy(this, 'NasboxIamPolicy', {
      policyName: 'NasboxCertbotRoute53Policy',
      roles: [nasboxRole],
    });

    // Permissions required by certbot-dns-route53 for DNS-01 challenge
    nasboxPolicy.addStatements(
      new iam.PolicyStatement({
        sid: 'Route53ChangeRecords',
        actions: ['route53:ChangeResourceRecordSets'],
        effect: iam.Effect.ALLOW,
        resources: [hostedZone.hostedZoneArn],
      }),
      new iam.PolicyStatement({
        sid: 'Route53ListZones',
        actions: ['route53:ListHostedZones', 'route53:ListHostedZonesByName'],
        effect: iam.Effect.ALLOW,
        resources: ['*'],
      }),
      new iam.PolicyStatement({
        sid: 'Route53GetChange',
        actions: ['route53:GetChange'],
        effect: iam.Effect.ALLOW,
        resources: ['arn:aws:route53:::change/*'],
      }),
    );

    // ── IoT role alias ────────────────────────────────────────────────────────
    const roleAlias = new iot.CfnRoleAlias(this, 'NasboxRoleAlias', {
      roleAlias: ROLE_ALIAS,
      credentialDurationSeconds: 3600,
      roleArn: nasboxRole.roleArn,
    });

    // ── IoT policy ────────────────────────────────────────────────────────────
    // Attached to the certificate; grants permission to exchange the cert
    // for temporary AWS credentials via the credential provider endpoint.
    const iotPolicy = new iot.CfnPolicy(this, 'NasboxIotPolicy', {
      policyName: 'NasboxAssumeRolePolicy',
      policyDocument: {
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Action: 'iot:AssumeRoleWithCertificate',
            Resource: roleAlias.attrRoleAliasArn,
          },
        ],
      },
    });

    // Attach IoT policy to the certificate
    const policyAttachment = new iot.CfnPolicyPrincipalAttachment(this, 'NasboxPolicyAttachment', {
      policyName: iotPolicy.policyName!,
      principal: certArn,
    });
    policyAttachment.addDependency(iotPolicy);

    // ── Outputs ───────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'ThingArn', {
      value: thingArn,
      description: 'ARN of the nasbox IoT Thing',
    });
    new cdk.CfnOutput(this, 'CertificateArn', {
      value: certArn,
      description: 'ARN of the IoT certificate',
    });
    new cdk.CfnOutput(this, 'RoleAlias', {
      value: ROLE_ALIAS,
      description: 'IoT role alias — used by the Pi to obtain temporary credentials',
    });
    new cdk.CfnOutput(this, 'SsmCertParam', {
      value: '/nasbox/certPem',
      description: 'SSM parameter containing the device certificate PEM',
    });
    new cdk.CfnOutput(this, 'SsmPrivKeyParam', {
      value: '/nasbox/privKey',
      description: 'SSM parameter containing the device private key',
    });
  }
}
