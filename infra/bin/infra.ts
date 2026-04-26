#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import * as fs from 'fs';
import { NasboxIotStack } from '../lib/nasbox-iot-stack';

const app = new cdk.App();

new NasboxIotStack(app, 'NasboxIotStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});

const { version: infraVersion } = JSON.parse(fs.readFileSync('./version.json', 'utf-8'));
cdk.Tags.of(app).add('MH-Project', 'nasbox');
cdk.Tags.of(app).add('MH-Version', infraVersion);
